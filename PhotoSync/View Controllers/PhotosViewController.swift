////
////  PhotosViewController.swift
////  PhotoSync
////
////  Created by Thomas Insam on 4/10/20.
////  Copyright © 2020 Thomas Insam. All rights reserved.
////
//
// import UIKit
// import SwiftyDropbox
// import CoreData
//
// class PhotosViewController: UIViewController {
//
//    lazy var fetchedResultsController = NSFetchedResultsController<Photo>(
//        fetchRequest: Photo.fetch(),
//        managedObjectContext: AppDelegate.shared.persistentContainer.viewContext,
//        sectionNameKeyPath: nil,
//        cacheName: nil).configured {
//            // One note here - we do _not_ set a delegate on this object! We change thousands
//            // of objects in the background, this will completely overwhelm the chagne tracking
//            // and lock the UI thread. Subscribe to the PhotoKitManagerSyncComplete notification instead.
//            try! $0.performFetch()
//    }
//
//    lazy var layout = UICollectionViewFlowLayout().configured {
//        $0.itemSize = CGSize(width: 50, height: 50)
//        $0.minimumInteritemSpacing = 0
//        $0.minimumLineSpacing = 1
//    }
//
//    lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout).configured {
//        $0.registerReusableCell(PhotoCell.self)
//        $0.backgroundColor = .systemGroupedBackground
//        $0.delegate = self
//        $0.dataSource = self
//    }
//
//    lazy var refreshControl = UIRefreshControl()
//
//    init() {
//        super.init(nibName: nil, bundle: nil)
//    }
//
//    required init?(coder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//
//    override func viewDidLoad() {
//        super.viewDidLoad()
//
//        NotificationCenter.default.addObserver(self, selector: #selector(syncProgress(_:)), name: .PhotoKitManagerSyncProgress, object: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(syncProgress(_:)), name: .SyncManagerSyncProgress, object: nil)
//
//        view.addSubviewWithConstraints(collectionView)
//        collectionView.refreshControl = refreshControl
//
//        refreshControl.addAction(for: .valueChanged) { [weak self] in
//            self?.refreshControl.attributedTitle = NSAttributedString(string: " ")
//            AppDelegate.shared.photoKitManager.sync()
//            AppDelegate.shared.dropboxManager.sync()
//        }
//
//        collectionView.pinEdgesTo(view: view)
//        collectionView.contentInsetAdjustmentBehavior = .always
//
//        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Sync") {
//            AppDelegate.shared.syncManager.sync()
//        }
//    }
//
//    override func viewDidLayoutSubviews() {
//        let width = collectionView.frame.width
//        let count = (width / 100).rounded(.down) // we want cells to be at least this wide, so this is how many will fit.
//        let cell = width / count - (count - 1) // The width of the cell, allowing for spacing
//        layout.itemSize = .init(width: cell, height: cell)
//        layout.minimumLineSpacing = (width - (cell * count)) / (count - 1) // make the line spacing the same as the item spacing
//        layout.invalidateLayout()
//    }
//
//    @objc func syncProgress(_ notification: Notification) {
//        guard let progress = notification.object as? Progress else { return }
//
//        if progress.completedUnitCount >= progress.totalUnitCount {
//            // complete
//            try! fetchedResultsController.performFetch()
//            collectionView.reloadData()
//            refreshControl.endRefreshing()
//        } else {
//            if !refreshControl.isRefreshing {
//                refreshControl.beginRefreshing()
//            }
//            refreshControl.attributedTitle = NSAttributedString(string: String(format: "%0.0f%% complete", progress.fractionCompleted * 100))
//        }
//
//        if fetchedResultsController.fetchedObjects?.count == 0 {
//            // Not going to update every time, but we'll load in the first page,
//            // because that'll be the most recently added photos. Anything we
//            // pull in later will almost certainly not be visible and I don't want
//            // the jank.
//            try! fetchedResultsController.performFetch()
//            collectionView.reloadData()
//        }
//    }
//
// }
//
// extension PhotosViewController: UICollectionViewDelegate, UICollectionViewDataSource {
//    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
//        return fetchedResultsController.sections?[section].numberOfObjects ?? 0
//    }
//
//    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
//        let cell: PhotoCell = collectionView.dequeueReusableCell(for: indexPath)
//        let photo = fetchedResultsController.object(at: indexPath)
//        cell.display(photo: photo)
//        return cell
//    }
//
// }
