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

package import NIOCore

/// A timer backed by `NIOScheduledCallback`.
package final class Timer<Handler: NIOScheduledCallbackHandler> where Handler: Sendable {
  /// The event loop on which to run this timer.
  private let eventLoop: any EventLoop

  /// The duration of the timer.
  private let duration: TimeAmount

  /// Whether this timer should repeat.
  private let repeating: Bool

  /// How far each run may stray from `duration`, as a fraction of it (0...1). Zero keeps the
  /// period exact, as upstream.
  private let jitter: Double

  /// The handler to call when the timer fires.
  private let handler: Handler

  /// The currently scheduled callback if the timer is running.
  private var scheduledCallback: NIOScheduledCallback?

  package init(
    eventLoop: any EventLoop,
    duration: TimeAmount,
    repeating: Bool,
    jitter: Double = 0,
    handler: Handler
  ) {
    self.eventLoop = eventLoop
    self.duration = duration
    self.repeating = repeating
    self.jitter = jitter
    self.handler = handler
    self.scheduledCallback = nil
  }

  /// Cancel the timer, if it is running.
  package func cancel() {
    self.eventLoop.assertInEventLoop()
    guard let scheduledCallback = self.scheduledCallback else { return }
    scheduledCallback.cancel()
  }

  /// Start or restart the timer.
  package func start() {
    self.eventLoop.assertInEventLoop()
    self.scheduledCallback?.cancel()
    // Only throws if the event loop is shutting down, so we'll just swallow the error here.
    let delay = Self.jittered(self.duration, jitter: self.jitter, unit: .random(in: 0..<1))
    self.scheduledCallback = try? self.eventLoop.scheduleCallback(in: delay, handler: self)
  }

  /// `duration` scaled by a factor in `[1 - jitter, 1 + jitter)`, picked by `unit` in `[0, 1)`.
  /// A strictly periodic ping is a rhythm an observer reads with one rule; this smears it.
  package static func jittered(_ duration: TimeAmount, jitter: Double, unit: Double) -> TimeAmount {
    let jitter = min(max(jitter, 0), 1)
    guard jitter > 0 else { return duration }
    let factor = 1 - jitter + 2 * jitter * unit
    return .nanoseconds(Int64(Double(duration.nanoseconds) * factor))
  }
}

extension Timer: NIOScheduledCallbackHandler, @unchecked Sendable where Handler: Sendable {
  /// For repeated timer support, the timer itself proxies the callback and restarts the timer.
  ///
  /// - NOTE: Users should not call this function directly.
  package func handleScheduledCallback(eventLoop: some EventLoop) {
    self.eventLoop.assertInEventLoop()
    self.handler.handleScheduledCallback(eventLoop: eventLoop)
    if self.repeating { self.start() }
  }
}
