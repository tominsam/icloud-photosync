//
//  StatusViewController.swift
//  PhotoSync
//
//  Created by Thomas Insam on 4/12/20.
//  Copyright © 2020 Thomas Insam. All rights reserved.
//

import UIKit

class StatusViewController: UIViewController {
    private var syncManager: SyncManager

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

    init(syncManager: SyncManager) {
        self.syncManager = syncManager
        super.init(nibName: nil, bundle: nil)
        syncManager.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        render()
    }

    func render() {
        switch syncManager.photoState {
        case .none:
            photoKitStatusLabel.text = "Not started"
        case let .some(serviceState):
            if serviceState.complete {
                photoKitStatusLabel.text = "Finished (\(serviceState.total) photos)"
            } else {
                photoKitStatusLabel.text = "Syncing (\(serviceState.progress) / \(serviceState.total) photos)"
            }
        }

        switch syncManager.dropboxState {
        case .none:
            dropboxStatusLabel.text = "Not started"
        case let .some(serviceState):
            if serviceState.complete {
                dropboxStatusLabel.text = "Finished (\(serviceState.total) files)"
            } else {
                dropboxStatusLabel.text = "Syncing (\(serviceState.progress) / \(serviceState.total) files)"
            }
            if !serviceState.errors.isEmpty {
                dropboxStatusLabel.text = "Error: \(serviceState.errors)"
            }
        }

        switch syncManager.uploadState {
        case .none:
            syncStatusLabel.text = "Not started"
        case let .some(serviceState):
            if !serviceState.errors.isEmpty {
                syncStatusLabel.text = "Failed (\(serviceState.errors.count) errors)"
            } else if serviceState.complete {
                syncStatusLabel.text = "Success!"
            } else {
                syncStatusLabel.text = "Uploading \(serviceState.progress) / \(serviceState.total)"
            }
        }

        errorsView.reloadData()
    }
}

extension StatusViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        return syncManager.errors.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Boring", for: indexPath)
        cell.textLabel?.text = syncManager.errors[indexPath.row]
        return cell
    }
}

extension StatusViewController: SyncManagerDelegate {
    func syncManagerUpdatedState(_: SyncManager) {
        render()
    }
}
