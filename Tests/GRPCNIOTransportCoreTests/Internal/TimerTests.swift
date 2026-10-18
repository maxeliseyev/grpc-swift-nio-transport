/*
 * Copyright 2024, gRPC Authors All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import GRPCCore
import GRPCNIOTransportCore
import NIOCore
import NIOEmbedded
import Synchronization
import XCTest

@available(gRPCSwiftNIOTransport 2.0, *)
internal final class TimerTests: XCTestCase {
  fileprivate struct CounterTimerHandler: NIOScheduledCallbackHandler {
    let counter = AtomicCounter(0)

    func handleScheduledCallback(eventLoop: some EventLoop) {
      counter.increment()
    }
  }

  func testOneOffTimer() {
    let loop = EmbeddedEventLoop()
    defer { try! loop.close() }

    let handler = CounterTimerHandler()
    let timer = Timer(eventLoop: loop, duration: .seconds(1), repeating: false, handler: handler)
    timer.start()

    // Timer hasn't fired because we haven't reached the required duration.
    loop.advanceTime(by: .milliseconds(999))
    XCTAssertEqual(handler.counter.value, 0)

    // Timer has fired once.
    loop.advanceTime(by: .milliseconds(1))
    XCTAssertEqual(handler.counter.value, 1)

    // Timer does not repeat.
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 1)

    // Timer can be restarted and then fires again after the duration.
    timer.start()
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 2)

    // Timer can be cancelled before the duration and then does not fire.
    timer.start()
    loop.advanceTime(by: .milliseconds(999))
    timer.cancel()
    loop.advanceTime(by: .milliseconds(1))
    XCTAssertEqual(handler.counter.value, 2)

    // Timer can be restarted after being cancelled.
    timer.start()
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 3)
  }

  func testRepeatedTimer() {
    let loop = EmbeddedEventLoop()
    defer { try! loop.close() }

    let handler = CounterTimerHandler()
    let timer = Timer(eventLoop: loop, duration: .seconds(1), repeating: true, handler: handler)
    timer.start()

    // Timer hasn't fired because we haven't reached the required duration.
    loop.advanceTime(by: .milliseconds(999))
    XCTAssertEqual(handler.counter.value, 0)

    // Timer has fired once.
    loop.advanceTime(by: .milliseconds(1))
    XCTAssertEqual(handler.counter.value, 1)

    // Timer hasn't fired again because we haven't reached the required duration again.
    loop.advanceTime(by: .milliseconds(999))
    XCTAssertEqual(handler.counter.value, 1)

    // Timer has fired again.
    loop.advanceTime(by: .milliseconds(1))
    XCTAssertEqual(handler.counter.value, 2)

    // Timer continues to fire on each second.
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 3)
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 4)
    loop.advanceTime(by: .seconds(1))
    XCTAssertEqual(handler.counter.value, 5)
    loop.advanceTime(by: .seconds(5))
    XCTAssertEqual(handler.counter.value, 10)

    // Timer does not fire again, after being cancelled.
    timer.cancel()
    loop.advanceTime(by: .seconds(5))
    XCTAssertEqual(handler.counter.value, 10)

    // Timer can be restarted after being cancelled and continues to fire once per second.
    timer.start()
    loop.advanceTime(by: .seconds(5))
    XCTAssertEqual(handler.counter.value, 15)
  }

  func testZeroJitterKeepsThePeriodExact() {
    for unit in [0.0, 0.5, 0.999] {
      XCTAssertEqual(
        Timer<CounterTimerHandler>.jittered(.seconds(15), jitter: 0, unit: unit),
        .seconds(15)
      )
    }
  }

  func testJitterStaysInItsCorridor() {
    let low = Timer<CounterTimerHandler>.jittered(.seconds(10), jitter: 0.3, unit: 0)
    let high = Timer<CounterTimerHandler>.jittered(.seconds(10), jitter: 0.3, unit: 0.999_999)
    XCTAssertEqual(low, .seconds(7))
    XCTAssertLessThan(high, .seconds(13))
    XCTAssertGreaterThan(high, .milliseconds(12_999))
  }

  func testJitteredIntervalsDiffer() {
    let intervals = (0..<100).map { _ in
      Timer<CounterTimerHandler>.jittered(.seconds(15), jitter: 0.3, unit: .random(in: 0..<1))
    }
    for interval in intervals {
      XCTAssertGreaterThanOrEqual(interval, .milliseconds(10_500))
      XCTAssertLessThan(interval, .milliseconds(19_500))
    }
    XCTAssertGreaterThan(Set(intervals.map(\.nanoseconds)).count, 50)
  }

  func testJitterIsClampedToTheDuration() {
    XCTAssertEqual(Timer<CounterTimerHandler>.jittered(.seconds(10), jitter: 5, unit: 0), .seconds(0))
    XCTAssertEqual(Timer<CounterTimerHandler>.jittered(.seconds(10), jitter: -1, unit: 0.7), .seconds(10))
  }

  /// The timer uses the jittered delay, not `duration`: of twenty timers, some fire before it.
  func testAJitteredTimerDoesNotFireOnTheDuration() {
    let loop = EmbeddedEventLoop()
    defer { try! loop.close() }
    let handlers = (0..<20).map { _ in CounterTimerHandler() }
    let timers = handlers.map {
      Timer(eventLoop: loop, duration: .seconds(10), repeating: false, jitter: 0.3, handler: $0)
    }
    timers.forEach { $0.start() }
    loop.advanceTime(by: .milliseconds(9_990))
    XCTAssertGreaterThan(handlers.filter { $0.counter.value > 0 }.count, 0)
    loop.advanceTime(by: .seconds(4))
    XCTAssertEqual(handlers.filter { $0.counter.value > 0 }.count, 20)
  }
}
