import XCTest

/// The community feed: composing, what a post needs before it can be sent, and what the row shows
/// once it is there.
///
/// Nothing is seeded into this feed — every post these tests read is one they wrote first, which is
/// also the only way a post ever gets into a shipping build.
final class CommunityUITests: FloweUITestCase {

    private func openCommunity(seeded: Bool = true) {
        launch(as: .student, seeded: seeded)
        selectTab("Community")
    }

    private func openComposer() {
        openCommunity()
        let compose = app.buttons["community.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: timeout), "Compose button missing")
        compose.tap()
    }

    private func typeCaption(_ text: String) {
        let field = app.textFields["compose.text"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Caption field missing")
        field.tap()
        field.typeText(text)
    }

    // MARK: - Empty state

    func testEmptyFeedOffersToWriteTheFirstPost() {
        openCommunity(seeded: false)
        XCTAssertTrue(waitForAnyText(["Nothing here yet"]), "Empty state missing")
        XCTAssertNotNil(anyStaticText(["Share the first post"]),
                        "The empty state should offer a way out of itself")
    }

    func testEmptyStateActionOpensTheComposer() {
        openCommunity(seeded: false)
        tapText(["Share the first post"])
        XCTAssertTrue(app.buttons["compose.post"].waitForExistence(timeout: timeout),
                      "The empty state's action should open the composer")
    }

    // MARK: - Composer

    func testComposerOffersAPhotoPicker() {
        openComposer()
        XCTAssertTrue(app.buttons["compose.photoPicker"].waitForExistence(timeout: timeout),
                      "A post should be able to carry a photo")
    }

    /// A post needs *something* — but only one of the two things.
    func testPostIsBlockedUntilThereIsACaptionOrAPhoto() {
        openComposer()
        XCTAssertTrue(app.buttons["compose.post"].waitForExistence(timeout: timeout),
                      "Post button missing")
        XCTAssertFalse(app.buttons["compose.post"].isEnabled,
                       "An empty post — no caption, no photo — shouldn't be postable")

        typeCaption("Breath first, then the powerhouse.")
        XCTAssertTrue(waitUntil({ app.buttons["compose.post"].isEnabled }),
                      "A caption alone should be enough to post")
    }

    /// Nothing is offered to remove until a photo has actually been chosen.
    func testRemovePhotoIsAbsentUntilOneIsPicked() {
        openComposer()
        XCTAssertTrue(app.buttons["compose.photoPicker"].waitForExistence(timeout: timeout),
                      "Photo picker missing")
        XCTAssertFalse(app.buttons["compose.photoRemove"].exists,
                       "There is nothing to remove before a photo is picked")
    }

    // MARK: - Posting

    func testACaptionOnlyPostAppearsInTheFeed() {
        openComposer()
        let caption = "Quality over count, always."
        typeCaption(caption)
        app.buttons["compose.post"].tap()

        XCTAssertTrue(waitForAnyText([caption], timeout: 15),
                      "A posted caption should show up in the feed")
        XCTAssertNil(anyStaticText(["Nothing here yet"]),
                     "The empty state should be gone once a post exists")
    }

    /// The row's own controls only exist once there is a post to carry them.
    func testAPostedRowCarriesTheFeedActions() {
        openComposer()
        typeCaption("Reformer footwork, slowly.")
        app.buttons["compose.post"].tap()

        XCTAssertTrue(app.buttons["post.like"].firstMatch.waitForExistence(timeout: 15),
                      "Like button missing from the posted row")
        XCTAssertTrue(app.buttons["post.comments"].firstMatch.exists, "Comment button missing")
        XCTAssertTrue(app.buttons["post.save"].firstMatch.exists, "Save button missing")
    }

    /// Zero is not a number worth printing under a post — the count appears with the first like.
    func testLikeCountAppearsOnlyOnceSomeoneHasLiked() {
        openComposer()
        typeCaption("Find your exhale.")
        app.buttons["compose.post"].tap()

        let like = app.buttons["post.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 15), "Like button missing")
        XCTAssertNil(anyStaticText(["0 likes", "0 like"]),
                     "An unliked post shouldn't announce that it has no likes")

        like.tap()
        XCTAssertTrue(waitForAnyText(["1 like"]),
                      "The first like should read '1 like', not '1 likes'")
    }

    func testAPostSurvivesLeavingAndReturningToTheTab() {
        openComposer()
        let caption = "Slow is smooth."
        typeCaption(caption)
        app.buttons["compose.post"].tap()
        XCTAssertTrue(waitForAnyText([caption], timeout: 15), "Post didn't appear")

        selectTab("Discover")
        selectTab("Community")
        XCTAssertTrue(waitForAnyText([caption], timeout: 15),
                      "The post should still be there after leaving the tab")
    }

    /// The author of a post gets Delete, never Report — you don't report yourself.
    func testOwnPostOffersDeleteRatherThanReport() {
        openComposer()
        typeCaption("Contrology, properly.")
        app.buttons["compose.post"].tap()

        let menu = app.buttons["post.moderation"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "Moderation menu missing")
        menu.tap()

        XCTAssertTrue(app.buttons["Delete Post"].waitForExistence(timeout: timeout),
                      "An author should be offered Delete on their own post")
        XCTAssertFalse(app.buttons["Report Post"].exists,
                       "An author shouldn't be offered Report on their own post")
    }
}
