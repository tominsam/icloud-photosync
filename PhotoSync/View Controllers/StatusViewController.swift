//
//  StatusViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit
import SwiftUI

class StatusViewModel: ObservableObject {
    @Published
    var photosState: String = ""
    @Published
    var photosProgress: Double = 0

    @Published
    var dropboxState: String = ""
    @Published
    var dropboxProgress: Double = 0

    @Published
    var uploadState: String = ""
    @Published
    var uploadProgress: Double = 0

    @Published
    var errors: [ServiceError] = []
}

struct LeadingTrailingLabel: View {
    let leading: String
    let trailing: String
    let progress: Double

    var body: some View {
        ZStack {
            // background is a progress bar that fills up behind the label
            GeometryReader { metrics in
                HStack(spacing: .zero) {
                    Color.green
                        .opacity(0.3)
                        .frame(width: metrics.size.width * progress)
                }
            }

            HStack {
                Text(leading).fixedSize(horizontal: true, vertical: true)
                Spacer()
                Text(trailing)
            }.padding()
        }
    }

}

struct StatusView: View {

    @ObservedObject
    var viewModel: StatusViewModel

    var body: some View {
        VStack {
            VStack(alignment: .leading) {
                Text("Sync").font(.title).padding()
                LeadingTrailingLabel(leading: "Photos database", trailing: viewModel.photosState, progress: viewModel.photosProgress)
                LeadingTrailingLabel(leading: "Dropbox", trailing: viewModel.dropboxState, progress: viewModel.dropboxProgress)
                LeadingTrailingLabel(leading: "Upload", trailing: viewModel.uploadState, progress: viewModel.uploadProgress)

                Divider()
                Text("Errors").font(.title).padding()

            }.fixedSize(horizontal: false, vertical: true)

            Table(viewModel.errors) {
                TableColumn("Path", value: \.path)
                TableColumn("Messasge", value: \.message)
            }.frame(maxHeight: .infinity)
        }
    }
}

class StatusViewController: UIHostingController<StatusView>, SyncManagerDelegate {

    var syncManager: SyncManager

    var viewModel = StatusViewModel()

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
        super.init(rootView: StatusView(viewModel: viewModel))
        syncManager.delegate = self
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncManagerUpdatedState(_ syncManager: SyncManager) {
        render()
    }

    func render() {
        assert(Thread.isMainThread)
        switch syncManager.photoState {
        case .none:
            viewModel.photosState = "Not started"
        case let .some(serviceState):
            if serviceState.complete {
                if serviceState.errors.isEmpty {
                    viewModel.photosState = "Complete (found \(serviceState.total) photos)"
                    viewModel.photosProgress = 1
                } else {
                    viewModel.photosState = "Failed (\(serviceState.errors.count) errors)"
                    viewModel.photosProgress = 0
                }
            } else {
                viewModel.photosState = "Fetching \(serviceState.progress) / \(serviceState.total)"
                viewModel.photosProgress = Double(serviceState.progress) / Double(serviceState.total)
            }
        }

        switch syncManager.dropboxState {
        case .none:
            viewModel.dropboxState = "Not started"
        case let .some(serviceState):
            if serviceState.complete {
                if serviceState.errors.isEmpty {
                    viewModel.dropboxState = "Complete (found \(serviceState.total) files)"
                    viewModel.dropboxProgress = 1
                } else {
                    viewModel.dropboxState = "Failed (\(serviceState.errors.count) errors)"
                    viewModel.dropboxProgress = 0
                }
            } else {
                viewModel.dropboxState = "Fetching \(serviceState.progress) / \(serviceState.total)"
                viewModel.dropboxProgress = Double(serviceState.progress) / Double(serviceState.total)
            }
        }

        switch syncManager.uploadState {
        case .none:
            viewModel.uploadState = "Not started"
        case let .some(serviceState):
            if serviceState.complete {
                if serviceState.errors.isEmpty {
                    viewModel.uploadState = "Complete"
                    viewModel.uploadProgress = 1
                } else {
                    viewModel.uploadState = "Failed (\(serviceState.errors.count) errors)"
                    viewModel.uploadProgress = 0
                }
            } else {
                viewModel.uploadState = "Uploaded \(serviceState.progress) / \(serviceState.total)"
                viewModel.uploadProgress = Double(serviceState.progress) / Double(serviceState.total)
            }
        }

        viewModel.errors = syncManager.errors
    }
}
