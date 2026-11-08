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

  // D52: phone notices follow the demo define only; release has none.
  func testPhoneNoticeDefinesParse() {
    func enc(_ items: [String]) -> String {
      items.map { Data($0.utf8).base64EncodedString() }.joined(separator: ",")
    }
    XCTAssertTrue(PhoneNoticeBuild.parse(defines: enc(["VERITRA_DEMO=true"])))
    XCTAssertTrue(PhoneNoticeBuild.parse(defines: enc(["VERITRA_DEMO=true", "VERITRA_PHONE_NOTICES=true"])))
    XCTAssertFalse(PhoneNoticeBuild.parse(defines: enc(["VERITRA_DEMO=true", "VERITRA_PHONE_NOTICES=false"])))
    XCTAssertTrue(PhoneNoticeBuild.parse(defines: enc(["VERITRA_PHONE_NOTICES=false", "VERITRA_PHONE_NOTICES=true", "VERITRA_DEMO=true"])))
    XCTAssertFalse(PhoneNoticeBuild.parse(defines: enc(["VERITRA_PHONE_NOTICES=true"])))
    XCTAssertFalse(PhoneNoticeBuild.parse(defines: enc(["VERITRA_DEMO=false"])))
    XCTAssertFalse(PhoneNoticeBuild.parse(defines: ""))
    XCTAssertFalse(PhoneNoticeBuild.parse(defines: "not-base64!,%%%"))
  }

  func testGenericNoticeTextIsBundled() {
    let text = NSLocalizedString("veritra.notification.new_message",
                                 bundle: Bundle(for: AppDelegate.self), comment: "")
    XCTAssertNotEqual(text, "veritra.notification.new_message")
  }
}
