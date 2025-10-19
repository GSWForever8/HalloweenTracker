//
//  TrackerView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/17/25.
//

import SwiftUI
import MapKit

struct CoordinatePin: Identifiable {
    let id = UUID()
    let coord: CLLocationCoordinate2D
}

struct TrackerView: View {
    let lat: Double?
    let lng: Double?

    // initial camera
    @State private var position: MapCameraPosition

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
        print(lat)
        print(lng)
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
    }

    var body: some View {
        let centerCord = CLLocationCoordinate2D(latitude: lat!, longitude: lng!)
        Map(position: $position) {
            // a simple marker
            MapCircle(center: centerCord,radius:50).foregroundStyle(Color.orange.opacity(0.6))            // or: MapPin / MapCircle etc.
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { recenter() }
        .onChange(of: lat) { _, _ in recenter() }   // ⟵ when lat changes
        .onChange(of: lng) { _, _ in recenter() }
    }
    private func recenter() {
        guard let lat, let lng else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        withAnimation { position = .region(region) }
    }
}
#Preview{
    TrackerView(lat: 37.00, lng: -117.00)
}
