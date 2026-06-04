//
//  Item.swift
//  ClaudeDesk
//
//  Created by Changxi Liu on 2026/6/4.
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
