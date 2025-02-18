// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html';
import 'dart:typed_data';

import 'base_client.dart';
import 'base_request.dart';
import 'byte_stream.dart';
import 'cancelation_token.dart';
import 'exception.dart';
import 'streamed_response.dart';

/// Create a [BrowserClient].
///
/// Used from conditional imports, matches the definition in `client_stub.dart`.
BaseClient createClient() => BrowserClient();

/// A `dart:html`-based HTTP client that runs in the browser and is backed by
/// XMLHttpRequests.
///
/// This client inherits some of the limitations of XMLHttpRequest. It ignores
/// the [BaseRequest.contentLength], [BaseRequest.persistentConnection],
/// [BaseRequest.followRedirects], and [BaseRequest.maxRedirects] fields. It is
/// also unable to stream requests or responses; a request will only be sent and
/// a response will only be returned once all the data is available.
class BrowserClient extends BaseClient {
  /// The currently active XHRs.
  ///
  /// These are aborted if the client is closed.
  final _xhrs = <CancellationToken>{};

  /// Whether to send credentials such as cookies or authorization headers for
  /// cross-site requests.
  ///
  /// Defaults to `false`.
  bool withCredentials = false;

  /// Sends an HTTP request and asynchronously returns the response.
  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    if (request.cancellationToken?.isCancellationPending == true) {
      throw ClientException('Request has been aborted', request.url);
    }

    var bytes = await request.finalize().toBytes();
    var xhr = HttpRequest();

    final cancellationToken =
        request.cancellationToken ?? CancellationToken(autoDispose: true);

    _xhrs.add(cancellationToken);

    xhr
      ..open(request.method, '${request.url}', async: true)
      ..responseType = 'arraybuffer'
      ..withCredentials = withCredentials;
    request.headers.forEach(xhr.setRequestHeader);

    var completer = Completer<StreamedResponse>();

    unawaited(xhr.onReadyStateChange
        .firstWhere((_) => xhr.readyState >= HttpRequest.HEADERS_RECEIVED)
        .then((value) => cancellationToken.registerRequest(xhr.abort,
            completer: completer, debugRequest: xhr, baseRequest: request)));

    unawaited(xhr.onLoad.first.then((_) {
      if (!completer.isCompleted) {
        var body = (xhr.response as ByteBuffer).asUint8List();
        completer.complete(StreamedResponse(
            ByteStream.fromBytes(body), xhr.status!,
            contentLength: body.length,
            request: request,
            headers: xhr.responseHeaders,
            reasonPhrase: xhr.statusText));
      }
    }));

    unawaited(xhr.onError.first.then((_) {
      // Unfortunately, the underlying XMLHttpRequest API doesn't expose any
      // specific information about the error itself.
      if (!completer.isCompleted) {
        completer.completeError(
            ClientException('XMLHttpRequest error.', request.url),
            StackTrace.current);
      }
    }));

    xhr.send(bytes);

    try {
      return await completer.future;
    } finally {
      await cancellationToken.completeRequest(request);
      _xhrs.remove(cancellationToken);
    }
  }

  /// Closes the client.
  ///
  /// This terminates all active requests.
  @override
  void close() {
    for (var xhr in _xhrs) {
      xhr.disposeToken();
    }
  }
}
