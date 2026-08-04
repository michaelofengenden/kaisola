import XCTest
@testable import Kaisola

/// macOS 26's headline desktops are *shuffles*, and the wallpaper store records
/// the shuffle rather than the picture: `shuffle-all-aerials`, where a pinned
/// wallpaper records an asset UUID.
///
/// That name is neither a still's filename nor a category in the manifest —
/// every real category is a UUID — so the lookup keyed on it matched nothing,
/// the resolution fell through to `.unavailable`, and the whole backdrop
/// rendered as the flat grey fallback. The glass was not erasing the wallpaper;
/// it had never been handed one.
final class ShuffledAerialDesktopTests: XCTestCase {
    func testTheShuffleSentinelIsRecognised() {
        XCTAssertTrue(DesktopWallpaperLocator.isShuffleAssetID("shuffle-all-aerials"))
        XCTAssertTrue(DesktopWallpaperLocator.isShuffleAssetID("shuffle-landscape"))
        // A real asset id is a UUID and must never be mistaken for a shuffle.
        XCTAssertFalse(
            DesktopWallpaperLocator.isShuffleAssetID("FE876489-CBD5-479B-A8F0-1B67F0741CEA")
        )
        XCTAssertFalse(DesktopWallpaperLocator.isShuffleAssetID(""))
    }

    /// The agent plays the aerial it is showing, so the most recently read
    /// video is the best evidence of the current pick.
    func testTheMostRecentlyPlayedAerialIsChosen() {
        let now = Date(timeIntervalSince1970: 1_785_800_000)
        let access = [
            (id: "old", accessedAt: now.addingTimeInterval(-9_000)),
            (id: "playing", accessedAt: now.addingTimeInterval(-60)),
            (id: "older", accessedAt: now.addingTimeInterval(-50_000)),
        ]
        XCTAssertEqual(
            DesktopWallpaperLocator.shuffledAerialStill(
                videoAccess: access,
                cachedStillIDs: ["old", "playing", "older"]
            ),
            "playing"
        )
    }

    /// A video with no cached still cannot be painted, so it must not win the
    /// pick and leave the backdrop pointing at a file that is not there.
    func testAVideoWithoutAStillIsSkipped() {
        let now = Date(timeIntervalSince1970: 1_785_800_000)
        let access = [
            (id: "no-still", accessedAt: now),
            (id: "has-still", accessedAt: now.addingTimeInterval(-3_600)),
        ]
        XCTAssertEqual(
            DesktopWallpaperLocator.shuffledAerialStill(
                videoAccess: access,
                cachedStillIDs: ["has-still"]
            ),
            "has-still"
        )
    }

    func testNoDownloadedVideosYieldsNoPick() {
        XCTAssertNil(
            DesktopWallpaperLocator.shuffledAerialStill(videoAccess: [], cachedStillIDs: ["a"])
        )
        XCTAssertNil(
            DesktopWallpaperLocator.shuffledAerialStill(
                videoAccess: [(id: "a", accessedAt: Date())],
                cachedStillIDs: []
            )
        )
    }

    /// The regression that started this: a shuffle id run through the
    /// *category* picker matches nothing, because manifest categories are all
    /// UUIDs. This is why it had to stop being the only path.
    func testAShuffleIDFindsNothingThroughTheCategoryPicker() throws {
        let manifest = try JSONSerialization.data(withJSONObject: [
            "assets": [
                ["id": "aaa", "categories": ["03F5E760-14E4-4856-9EC9-A3507A88FFA8"]],
                ["id": "bbb", "subcategories": ["05BF1D79-700D-4E28-9C3B-A55E04B6165D"]],
            ],
        ])
        XCTAssertNil(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "shuffle-all-aerials",
                manifest: manifest,
                cachedStillIDs: ["aaa", "bbb"]
            ),
            "a shuffle is not a category — this is the lookup that was returning nil"
        )
        // A genuine category still resolves, so the old path is intact.
        XCTAssertEqual(
            DesktopWallpaperLocator.representativeAerialStill(
                assetID: "03F5E760-14E4-4856-9EC9-A3507A88FFA8",
                manifest: manifest,
                cachedStillIDs: ["aaa", "bbb"]
            ),
            "aaa"
        )
    }
}
