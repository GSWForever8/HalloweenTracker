//
//  User.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import Foundation
struct User: Codable{
    var userId: String?
    var name: String
    var email: String
}

struct HealthData: Codable{
    var id: String?
    var userId: String
    var type: String
    var date: Date
    var steps: Int?
    var calories: Int?
}
