import 'dart:async';
import 'dart:convert';

import 'package:pubnub/core.dart';
import 'package:pubnub/pubnub.dart';

import '../_endpoints/subscribe.dart';
import 'subscribe_fiber.dart';
import 'subscribe_loop_state.dart';

final _logger = injectLogger('pubnub.subscribe.subscribe_loop');

/// @nodoc
typedef UpdateCallback = SubscribeLoopState Function(SubscribeLoopState state);

/// @nodoc
class UpdateException implements Exception {}

/// @nodoc
class CancelException implements Exception {}

/// @nodoc
Future<T> withCancel<T>(Future<T> future, Future<void> cancelSignal) async {
  return await Future.any([
    future,
    cancelSignal.then((_) => throw CancelException()),
  ]);
}

/// @nodoc
class SubscribeLoop {
  SubscribeLoopState _state;
  Core core;

  /// @nodoc
  SubscribeLoop(this.core, this._state) {
    _messagesController = StreamController.broadcast(
      onListen: () => update((state) {
        _logger.silly('777 onListen update isActive=true');
        return state.clone(isActive: true);
      }),
      onCancel: () => update((state) {
        _logger.silly('777 onCancel update isActive=false');
        return state.clone(isActive: false);
      }),
    );

    _whenStartsController = StreamController.broadcast();

    final loopStream = _loop();

    _loopStreamSubscription = loopStream.listen(
      (envelope) {
        _messagesController.add(envelope);
      },
      onError: (Object exception) {
        _messagesController.addError(exception);
      },
    );

    _networkConnectedSubscription = core.supervisor.signals.networkIsConnected
        .listen((_) => update((state) => state));
  }

  late StreamController<Envelope> _messagesController;

  Stream<Envelope> get envelopes => _messagesController.stream;

  late StreamController<void> _whenStartsController;

  Future<void> get whenStarts => _whenStartsController.stream.take(1).first;

  final StreamController<Exception> _queueController =
      StreamController.broadcast();

  late StreamSubscription<Envelope> _loopStreamSubscription;
  late StreamSubscription<bool> _networkConnectedSubscription;

  void update(UpdateCallback callback, {bool skipCancel = false}) {
    final newState = callback(_state);

    _state = newState;
    _logger.silly(
        '777 State has been updated ($newState). isErrored=${newState.isErrored} isActive=${newState.isActive} shouldRun=${newState.shouldRun}');

    if (skipCancel == false) {
      _queueController.add(CancelException());
    }
  }

  Stream<Envelope> _loop() async* {
    _logger.silly('_loop()');
    IRequestHandler? handler;
    var tries = 0;

    while (true) {
      _logger.silly('777 start loop 1 tries=$tries');

      final cancelCompleter = Completer<void>();

      final queueSubscription = _queueController.stream.listen((exception) {
        _logger
            .silly('777 _queueController.stream.listen: exception=$exception');
        if (!cancelCompleter.isCompleted) {
          cancelCompleter.complete();
        }
      });

      try {
        _logger.silly('777 Starting new loop iteration.');
        tries += 1;

        final customTimetoken = _state.customTimetoken;
        final state = _state;

        _logger.silly('777 checking !state.shouldRun=${!state.shouldRun}');
        if (!state.shouldRun) {
          _logger.silly('777 break');
          break;
        }

        _logger.silly('777 1 handler with cancel');
        // handler = await withCancel(
        //   core.networking.handler(),
        //   cancelCompleter.future,
        // );
        //handler = await core.networking.handler();

        final handlerFuture = core.networking.handler();
        await Future.any([handlerFuture, cancelCompleter.future]);
        if (cancelCompleter.isCompleted) {
          throw CancelException();
        }
        handler = await handlerFuture;

        // final objectFuture = core.parser.decode(response.text);
        // await Future.any([objectFuture, cancelCompleter.future]);
        // if (cancelCompleter.isCompleted) {
        //   throw CancelException();
        // }
        // final object = await objectFuture;

        final params = SubscribeParams(
          state.keyset,
          state.timetoken.value,
          region: state.region,
          channels: state.channels,
          channelGroups: state.channelGroups,
        );

        if (state.timetoken.value != BigInt.zero) {
          _whenStartsController.add(null);
        }

        _logger.silly('777 2 response with cancel');
        // Wait for either the response or the cancellation signal.
        // final response = await withCancel(
        //   handler!.response(params.toRequest()),
        //   cancelCompleter.future,
        // );

        final responseFuture = handler.response(params.toRequest());
        await Future.any([responseFuture, cancelCompleter.future]);
        if (cancelCompleter.isCompleted) {
          throw CancelException();
        }
        final response = await responseFuture;

        _logger.silly('777 3 got response ${response.text}');

        core.supervisor.notify(NetworkIsUpEvent());

        // final object = await withCancel(
        //   core.parser.decode<Map<String, dynamic>>(response.text),
        //   cancelCompleter.future,
        // );

        final objectFuture = core.parser.decode(response.text);
        await Future.any([objectFuture, cancelCompleter.future]);
        if (cancelCompleter.isCompleted) {
          throw CancelException();
        }
        final object = await objectFuture;

        _logger.silly('777 4 got object=$object');

        final result = SubscribeResult.fromJson(object);

        _logger.silly(
            '777 Result: timetoken ${result.timetoken}, new messages: ${result.messages.length}');

        yield* Stream.fromIterable(result.messages).asyncMap((object) async {
          if (object is Map<String, dynamic>) {
            if ((state.keyset.cipherKey != null ||
                    core.crypto is CryptoModule) &&
                (object['e'] == null || object['e'] == 4 || object['e'] == 0) &&
                !(object['c'].endsWith('-pnpres') as bool)) {
              try {
                _logger.info('Decrypting message...');
                if (!(object['d'] is String)) {
                  throw const FormatException('not a base64 String');
                }
                object['d'] = state.keyset.cipherKey ==
                        core.keysets.defaultKeyset.cipherKey
                    ? await core.parser.decode(utf8.decode(core.crypto.decrypt(
                        base64.decode(object['d'] as String).toList())))
                    : await core.parser.decode(utf8.decode(core.crypto
                        .decryptWithKey(state.keyset.cipherKey!,
                            base64.decode(object['d'] as String).toList())));
              } on PubNubException catch (e) {
                object['error'] = e;
              } on FormatException catch (e) {
                object['error'] = PubNubException(
                    'Can not decrypt the message payload. Please check keyset or crypto configuration. ${e.message}');
              }
            }
          }
          return Envelope.fromJson(object);
        });

        _logger.silly('777 Updating the state...');

        tries = 0;

        update(
          (state) => state.clone(
            timetoken: customTimetoken ?? result.timetoken,
            region: result.region,
          ),
        );
      } catch (exception) {
        _logger.silly('777 1 Caught an exception: $exception');

        final fiber = SubscribeFiber(tries);

        if (handler != null && !handler.isCancelled) {
          _logger.silly('777 1 Cancelling the handler...');
          handler.cancel();
        }

        if (exception is UpdateException || exception is CancelException) {
          _logger.silly('777 continue');
          continue;
        }

        _logger.warning(
            'An exception (${exception.runtimeType}) has occured while running a subscribe fiber (retry #$tries).');
        final diagnostic = core.supervisor.runDiagnostics(fiber, exception);

        if (diagnostic == null) {
          _logger.warning('No diagnostics found.');

          update((state) => state.clone(isErrored: true));
          yield* Stream<Envelope>.error(exception);
          continue;
        }

        _logger.silly('Possible reason found: $diagnostic');

        final resolutions = core.supervisor.runStrategies(fiber, diagnostic);

        if (resolutions == null) {
          _logger.silly('No resolutions found.');

          update((state) => state.clone(isErrored: true));
          yield* Stream<Envelope>.error(exception);
          continue;
        }

        for (final resolution in resolutions) {
          if (resolution is FailResolution) {
            update((state) => state.clone(isErrored: true));
            yield* Stream<Envelope>.error(exception);
            continue;
          } else if (resolution is DelayResolution) {
            await Future<dynamic>.delayed(resolution.delay);
          } else if (resolution is RetryResolution) {
            continue;
          } else if (resolution is NetworkStatusResolution) {
            core.supervisor.notify(
                resolution.isUp ? NetworkIsUpEvent() : NetworkIsDownEvent());
          }
        }
      } finally {
        _logger.silly('777 finally start');

        if (handler != null && !handler.isCancelled) {
          _logger.silly('777 2 Cancelling the handler...');
          handler.cancel();
        }
        handler = null;

        _logger.silly('777 start await queueSubscription.cancel()');

        /// When using withCancel above, await queueSubscription.cancel()
        /// hangs. The workaround is to not use withCancel.
        await queueSubscription.cancel();
        _logger.silly('777 end await queueSubscription.cancel()');

        _logger.silly('777 finally end');
      }
    }
    _logger.silly('777 out of while loop: closing streams');
    await _loopStreamSubscription.cancel();
    await _networkConnectedSubscription.cancel();
    await _queueController.close();
    await _whenStartsController.close();
    await _messagesController.close();
  }
}
