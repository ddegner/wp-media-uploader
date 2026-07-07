import SwiftUI
import XCTest
@testable import WordpressMediaUploaderApp

final class WorkspaceUIStateTests: XCTestCase {
    func testRestoredOperationsTabFallsBackToDefault() {
        XCTAssertEqual(
            WorkspaceLayoutState.restoredOperationsTab(from: "not-a-tab"),
            WorkspaceLayoutState.defaultOperationsTab
        )
    }

    func testRestoredOperationsTabUsesValidRawValue() {
        XCTAssertEqual(WorkspaceLayoutState.restoredOperationsTab(from: "terminal"), .terminal)
    }

    func testSplitVisibilityReflectsProfilesDrawer() {
        XCTAssertEqual(WorkspaceLayoutState.splitVisibility(forProfilesDrawer: true), .all)
        XCTAssertEqual(WorkspaceLayoutState.splitVisibility(forProfilesDrawer: false), .detailOnly)
    }

    func testProfilesDrawerVisibilityFromSplitState() {
        XCTAssertTrue(WorkspaceLayoutState.profilesDrawerVisible(for: .all))
        XCTAssertFalse(WorkspaceLayoutState.profilesDrawerVisible(for: .detailOnly))
    }

    func testInitialStateReadsPersistedDrawerValues() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkspaceUIStateTests-\(UUID().uuidString)"))

        // Unset keys fall back to defaults: both drawers visible, activeJob tab.
        XCTAssertEqual(WorkspaceLayoutState.initialSplitVisibility(defaults: defaults), .all)
        XCTAssertEqual(WorkspaceLayoutState.initialOperationsPane(defaults: defaults), .activeJob)

        defaults.set(false, forKey: WorkspaceLayoutState.showProfilesDrawerKey)
        defaults.set(true, forKey: WorkspaceLayoutState.showOperationsDrawerKey)
        defaults.set("terminal", forKey: WorkspaceLayoutState.operationsTabKey)
        XCTAssertEqual(WorkspaceLayoutState.initialSplitVisibility(defaults: defaults), .detailOnly)
        XCTAssertEqual(WorkspaceLayoutState.initialOperationsPane(defaults: defaults), .terminal)

        defaults.set(false, forKey: WorkspaceLayoutState.showOperationsDrawerKey)
        XCTAssertNil(WorkspaceLayoutState.initialOperationsPane(defaults: defaults))
    }

    func testCanStartUploadRequiresIdleProfileAndQueue() {
        XCTAssertTrue(WorkspaceCommandState.canStartUpload(isRunning: false, hasSelectedProfile: true, queuedCount: 1))
        XCTAssertFalse(WorkspaceCommandState.canStartUpload(isRunning: true, hasSelectedProfile: true, queuedCount: 1))
        XCTAssertFalse(WorkspaceCommandState.canStartUpload(isRunning: false, hasSelectedProfile: false, queuedCount: 1))
        XCTAssertFalse(WorkspaceCommandState.canStartUpload(isRunning: false, hasSelectedProfile: true, queuedCount: 0))
    }

    func testCanClearFilesRequiresIdleAndFilesOrJob() {
        XCTAssertTrue(WorkspaceCommandState.canClearFiles(isRunning: false, queuedCount: 1, hasCurrentJob: false))
        XCTAssertTrue(WorkspaceCommandState.canClearFiles(isRunning: false, queuedCount: 0, hasCurrentJob: true))
        XCTAssertFalse(WorkspaceCommandState.canClearFiles(isRunning: false, queuedCount: 0, hasCurrentJob: false))
        XCTAssertFalse(WorkspaceCommandState.canClearFiles(isRunning: true, queuedCount: 10, hasCurrentJob: true))
    }

    func testCanDeleteSelectedFilesRequiresQueuedSelection() {
        XCTAssertTrue(WorkspaceCommandState.canDeleteSelectedFiles(isRunning: false, selectedCount: 1, hasQueuedSelection: true))
        XCTAssertFalse(WorkspaceCommandState.canDeleteSelectedFiles(isRunning: false, selectedCount: 1, hasQueuedSelection: false))
        XCTAssertFalse(WorkspaceCommandState.canDeleteSelectedFiles(isRunning: false, selectedCount: 0, hasQueuedSelection: true))
        XCTAssertFalse(WorkspaceCommandState.canDeleteSelectedFiles(isRunning: true, selectedCount: 1, hasQueuedSelection: true))
    }

    func testCanClearJobHistoryRequiresIdleAndStoredJobs() {
        XCTAssertTrue(WorkspaceCommandState.canClearJobHistory(isRunning: false, jobCount: 1))
        XCTAssertFalse(WorkspaceCommandState.canClearJobHistory(isRunning: false, jobCount: 0))
        XCTAssertFalse(WorkspaceCommandState.canClearJobHistory(isRunning: true, jobCount: 1))
    }
}
