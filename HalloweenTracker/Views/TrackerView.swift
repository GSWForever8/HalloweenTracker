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

    @State private var position: MapCameraPosition

    init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng

        let center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )))
    }

    var body: some View {
        VStack(spacing: 12) {
            let centerCoord = CLLocationCoordinate2D(latitude: lat!, longitude: lng!)

            Map(position: $position) {
                MapCircle(center: centerCoord, radius: 50)
                    .foregroundStyle(Color.orange.opacity(0.6))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear { recenter() }
            .onChange(of: lat) { _, _ in recenter() }
            .onChange(of: lng) { _, _ in recenter() }

            Button {
                openInAppleMaps()
            } label: {
                Label("Navigate with Apple Maps", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
    }

    private func recenter() {
        guard let lat, let lng else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        withAnimation { position = .region(region) }
    }

    private func openInAppleMaps() {
        guard let lat, let lng else { return }
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "Tracker Location"
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving
        ])
    }
}

#Preview {
    TrackerView(lat: 37.00, lng: -117.00)
}
