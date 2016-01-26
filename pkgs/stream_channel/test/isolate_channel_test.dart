// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:isolate';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'utils.dart';

void main() {
  var receivePort;
  var sendPort;
  var channel;
  setUp(() {
    receivePort = new ReceivePort();
    var receivePortForSend = new ReceivePort();
    sendPort = receivePortForSend.sendPort;
    channel = new IsolateChannel(receivePortForSend, receivePort.sendPort);
  });

  tearDown(() {
    receivePort.close();
    channel.sink.close();
  });

  test("the channel can send messages", () {
    channel.sink.add(1);
    channel.sink.add(2);
    channel.sink.add(3);

    expect(receivePort.take(3).toList(), completion(equals([1, 2, 3])));
  });

  test("the channel can receive messages", () {
    sendPort.send(1);
    sendPort.send(2);
    sendPort.send(3);

    expect(channel.stream.take(3).toList(), completion(equals([1, 2, 3])));
  });

  test("events can't be added to an explicitly-closed sink", () {
    expect(channel.sink.close(), completes);
    expect(() => channel.sink.add(1), throwsStateError);
    expect(() => channel.sink.addError("oh no"), throwsStateError);
    expect(() => channel.sink.addStream(new Stream.fromIterable([])),
        throwsStateError);
  });

  test("events can't be added while a stream is being added", () {
    var controller = new StreamController();
    channel.sink.addStream(controller.stream);

    expect(() => channel.sink.add(1), throwsStateError);
    expect(() => channel.sink.addError("oh no"), throwsStateError);
    expect(() => channel.sink.addStream(new Stream.fromIterable([])),
        throwsStateError);
    expect(() => channel.sink.close(), throwsStateError);

    controller.close();
  });

  group("stream channel rules", () {
    test("closing the sink causes the stream to close before it emits any more "
        "events", () {
      sendPort.send(1);
      sendPort.send(2);
      sendPort.send(3);
      sendPort.send(4);
      sendPort.send(5);

      channel.stream.listen(expectAsync((message) {
        expect(message, equals(1));
        channel.sink.close();
      }, count: 1));
    });

    test("cancelling the stream's subscription has no effect on the sink",
        () async {
      channel.stream.listen(null).cancel();
      await pumpEventQueue();

      channel.sink.add(1);
      channel.sink.add(2);
      channel.sink.add(3);
      expect(receivePort.take(3).toList(), completion(equals([1, 2, 3])));
    });

    test("the sink closes as soon as an error is added", () async {
      channel.sink.addError("oh no");
      channel.sink.add(1);
      expect(channel.sink.done, throwsA("oh no"));

      // Since the sink is closed, the stream should also be closed.
      expect(channel.stream.isEmpty, completion(isTrue));

      // The other end shouldn't receive the next event, since the sink was
      // closed. Pump the event queue to give it a chance to.
      receivePort.listen(expectAsync((_) {}, count: 0));
      await pumpEventQueue();
    });

    test("the sink closes as soon as an error is added via addStream",
        () async {
      var canceled = false;
      var controller = new StreamController(onCancel: () {
        canceled = true;
      });

      // This future shouldn't get the error, because it's sent to [Sink.done].
      expect(channel.sink.addStream(controller.stream), completes);

      controller.addError("oh no");
      expect(channel.sink.done, throwsA("oh no"));
      await pumpEventQueue();
      expect(canceled, isTrue);

      // Even though the sink is closed, this shouldn't throw an error because
      // the user didn't explicitly close it.
      channel.sink.add(1);
    });
  });
}
