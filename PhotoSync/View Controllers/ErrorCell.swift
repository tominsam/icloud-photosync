//
//  ErrorCell.swift
//  PhotoSync
//
//  Created by Thomas Insam on 2/3/22.
//

import Foundation
import UIKit

class ErrorCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
