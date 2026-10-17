import Testing
@testable import Tunes

struct SamplyPageTests {
    @Test func libraryTargetDoesNotIncludeAPreviouslySelectedAlbum() {
        let page = SamplyPage.library
        #expect(page.arguments["page"] as? String == "library")
        #expect(page.arguments["routeID"] == nil)
        #expect(page.arguments["groupID"] == nil)
        #expect(page.refreshLabel == "Refresh Library")
    }

    @Test func albumAndFolderTargetsKeepTheirExactIdentity() {
        let album = SamplyPage.album(routeID: "share /1", groupID: nil)
        #expect(album.arguments["routeID"] as? String == "share /1")
        #expect(album.arguments["groupID"] == nil)
        #expect(album.refreshLabel == "Refresh Album")
        let folder = SamplyPage.album(routeID: "share /1", groupID: "folder-2")
        #expect(folder.arguments["page"] as? String == "album")
        #expect(folder.arguments["routeID"] as? String == "share /1")
        #expect(folder.arguments["groupID"] as? String == "folder-2")
        #expect(folder.refreshLabel == "Refresh Folder")
    }
}
