//
//  StatusViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

class StatusViewController: UIViewController {

    private var dropboxManager = AppDelegate.shared.dropboxManager
    private var photoKitManager = AppDelegate.shared.photoKitManager
    private var syncManager = AppDelegate.shared.syncManager

    lazy var photoKitStatusTitle = UILabel().configured {
        $0.text = "Photo Database"
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .label
    }

    lazy var photoKitStatusLabel = UILabel().configured {
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }

    lazy var dropboxStatusTitle = UILabel().configured {
        $0.text = "Dropbox"
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .label
    }

    lazy var dropboxStatusLabel = UILabel().configured {
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }

    lazy var syncStatusTitle = UILabel().configured {
        $0.text = "Upload"
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .label
    }

    lazy var syncStatusLabel = UILabel().configured {
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 0
    }

    lazy var errorsTitle = UILabel().configured {
        $0.text = "Errors"
        $0.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        $0.textColor = .label
    }

    lazy var errorsView = UITableView(frame: .zero, style: .plain).configured {
        $0.allowsSelection = false
        $0.tableFooterView = UIView()
        $0.dataSource = self
        $0.delegate = self
        $0.register(UITableViewCell.self, forCellReuseIdentifier: "Boring")
        $0.estimatedRowHeight = UITableView.automaticDimension
        $0.separatorStyle = .none
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stackView = UIStackView(arrangedSubviews: [photoKitStatusTitle, photoKitStatusLabel, dropboxStatusTitle, dropboxStatusLabel, syncStatusTitle, syncStatusLabel, errorsTitle])
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.setCustomSpacing(24, after: photoKitStatusLabel)
        stackView.setCustomSpacing(24, after: dropboxStatusLabel)
        stackView.setCustomSpacing(24, after: syncStatusLabel)
        stackView.setCustomSpacing(16, after: errorsTitle)
        stackView.preservesSuperviewLayoutMargins = true
        stackView.isLayoutMarginsRelativeArrangement = true

        let mainStack = UIStackView(arrangedSubviews: [stackView, errorsView])
        mainStack.axis = .vertical
        mainStack.preservesSuperviewLayoutMargins = true

        view.addSubviewWithInsets(mainStack)

        NotificationCenter.default.addObserver(self, selector: #selector(syncProgress(_:)), name: .PhotoKitManagerSyncProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncProgress(_:)), name: .DropboxManagerSyncProgress, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncProgress(_:)), name: .SyncManagerSyncProgress, object: nil)
        render()
    }

    @objc func syncProgress(_ notification: Notification) {
        render()
        // TODO HACK start the upload once the files and photos are done, assuming it's not already started
        if syncManager.canSync, case .notStarted = syncManager.state {
            syncManager.sync()
        }
    }

    func render() {
        switch photoKitManager.state {
        case .notStarted:
            photoKitStatusLabel.text = "Not started"
        case .syncing:
            photoKitStatusLabel.text = "Syncing (\(photoKitManager.progress.completedUnitCount) / \(photoKitManager.progress.totalUnitCount) photos)"
        case .finished:
            photoKitStatusLabel.text = "Finished (\(photoKitManager.progress.totalUnitCount) photos)"
        }

        switch dropboxManager.state {
        case .notStarted:
            dropboxStatusLabel.text = "Not started"
        case .syncing:
            dropboxStatusLabel.text = "Syncing (\(dropboxManager.progress.completedUnitCount) / \(dropboxManager.progress.totalUnitCount) files)"
        case .finished:
            dropboxStatusLabel.text = "Finished (\(dropboxManager.progress.totalUnitCount) files)"
        case .error(let error):
            dropboxStatusLabel.text = "Error: \(error)"
        }

        switch syncManager.state {
        case .notStarted:
            syncStatusLabel.text = "Not started"
        case .syncing:
            syncStatusLabel.text = "Uploading \(syncManager.progress.completedUnitCount) / \(syncManager.progress.totalUnitCount)"
        case .finished:
            syncStatusLabel.text = "Success!"
        case .error(let errors):
            syncStatusLabel.text = "Failed (\(errors.count) errors)"
        }

        errorsView.reloadData()

    }

}

extension StatusViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return syncManager.errors.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Boring", for: indexPath)
        cell.textLabel?.text = syncManager.errors[indexPath.row]
        return cell
    }
}
