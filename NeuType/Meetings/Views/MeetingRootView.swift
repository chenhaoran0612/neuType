import SwiftUI

struct MeetingRootView: View {
    @StateObject private var listViewModel = MeetingListViewModel()

    var body: some View {
        NavigationSplitView {
            MeetingListView(viewModel: listViewModel)
        } detail: {
            MeetingRecorderView()
        }
    }
}
