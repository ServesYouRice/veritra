import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  // D53: a visible APNs alert replaces the local notice; an older server's
  // background-only push still gets one.
  func testLocalNoticeOnlyWithoutSystemAlert() {
    XCTAssertTrue(AppDelegate.carriesSystemAlert([
      "aps": ["alert": ["loc-key": "veritra.notification.new_message"], "content-available": 1],
      "version": "v1", "event": "new_encrypted_event_available",
    ]))
    XCTAssertFalse(AppDelegate.carriesSystemAlert([
      "aps": ["content-available": 1],
      "version": "v1", "event": "new_encrypted_event_available",
    ]))
    XCTAssertFalse(AppDelegate.carriesSystemAlert(["version": "v1"]))
  }

  func testGenericNoticeTextIsBundled() {
    let text = NSLocalizedString("veritra.notification.new_message",
                                 bundle: Bundle(for: AppDelegate.self), comment: "")
    XCTAssertNotEqual(text, "veritra.notification.new_message")
  }
}
