import 'package:pubnub/core.dart';
import 'package:pubnub/pubnub.dart';

import '../_endpoints/signal.dart';
import '../_utils/utils.dart';

export '../_endpoints/signal.dart';

mixin SignalDx on Core {
  /// Publishes signal [message] to a [channel].
  Future<SignalResult> signal(String channel, dynamic message,
      {Keyset? keyset, String? using}) async {
    keyset ??= keysets[using];
    Ensure(keyset.publishKey).isNotNull('publishKey');

    var payload = await super.parser.encode(message);
    var params = SignalParams(keyset, channel, payload);

    return defaultFlow(
        keyset: keyset,
        core: this,
        params: params,
        serialize: (object, [_]) => SignalResult.fromJson(object));
  }
}
