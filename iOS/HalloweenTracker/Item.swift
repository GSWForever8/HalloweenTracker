//
//  Item.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
