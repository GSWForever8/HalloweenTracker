import os
import uuid
from datetime import datetime, timezone
from typing import Optional, List

from flask import Flask, request, jsonify, abort
from flask_cors import CORS

from sqlalchemy import (
    String, Integer, Float, Boolean, DateTime, ForeignKey, create_engine, select, text
)
from sqlalchemy.orm import (
    DeclarativeBase, Mapped, mapped_column, relationship, Session
)

# -----------------------
# Config
# -----------------------
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///tracker.db")

# -----------------------
# SQLAlchemy setup
# -----------------------
class Base(DeclarativeBase):
    pass

class TrackerDevice(Base):
    """
    Mirrors Swift @Model TrackerDevice
    - bleId: UUID (unique)  -> stored as String PK
    - name: String
    - ownerUID: String
    - pairedAt: Date
    - isActive: Bool
    - lastSeenAt: Date?
    - lastRSSI: Int?
    - lastBatteryPercent: Int?
    - beaconMajor: Int
    - beaconMinor: Int
    """
    __tablename__ = "tracker_devices"

    ble_id: Mapped[str] = mapped_column("ble_id", String(36), primary_key=True)  # use as PK
    name: Mapped[str] = mapped_column(String(200))
    owner_uid: Mapped[str] = mapped_column(String(200))
    paired_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_seen_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    last_rssi: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    last_battery_percent: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    beacon_major: Mapped[int] = mapped_column(Integer)
    beacon_minor: Mapped[int] = mapped_column(Integer)
    lat: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    lng: Mapped[Optional[float]] = mapped_column(Float, nullable=True)


    def to_dict(self):
        ts = self.last_seen_at
        iso = ts.isoformat().replace("+00:00", "Z") if ts else None
        iso+="Z"
        return {
            "bleId": self.ble_id,
            "name": self.name,
            "ownerUID": self.owner_uid,
            "pairedAt": self.paired_at.isoformat(),
            "isActive": self.is_active,
            "lastSeenAt": iso if iso else None,
            "lastRSSI": self.last_rssi,
            "lastBatteryPercent": self.last_battery_percent,
            "beaconMajor": self.beacon_major,
            "beaconMinor": self.beacon_minor,
            "lat": self.lat,
            "lng": self.lng,
        }


class Users(Base):
    __tablename__ = "users"
    major: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    uid: Mapped[str] = mapped_column(String(50), unique=True, nullable=False)
    def to_dict(self):
        return {
            "major": self.major,
            "uid": self.uid,
        }
engine = create_engine(DATABASE_URL, future=True, echo=False)
Base.metadata.create_all(engine)

# -----------------------
# Flask app
# -----------------------
app = Flask(__name__)
CORS(app)

def parse_iso_datetime(value: str) -> datetime:
    # Accepts "2025-10-16T12:34:56Z" or with offset; default to UTC if naive.
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

# -----------------------
# Routes
# -----------------------
@app.get("/health")
def health():
    return {"ok": True}

# ---- Devices ----
@app.post("/link")
def link_user():
    data = request.get_json(force=True) or {}
    uid = data.get("uid", "")
    if not uid:
        abort(400, description="Missing 'uid' in request body")
    with Session(engine) as s:
        # Check if user already exists
        existing_user = s.scalars(select(Users).where(Users.uid == uid)).first()
        if existing_user:
            return existing_user.to_dict()

        user = Users(uid=uid)
        s.add(user)
        s.commit()
        s.refresh(user)
        return user.to_dict(), 201

@app.post("/majorGivenUID/")
def get_major_given_uid():
    data = request.get_json(force=True) or {}
    print(data)
    uid = data.get("uid", "")
    if not uid:
        abort(400, description="Missing 'uid' query parameter")
    with Session(engine) as s:
        user = s.scalars(select(Users).where(Users.uid == uid)).first()
        if not user:
            abort(404, description="User not found")
        return {"major": user.major}
    
@app.post("/getNextMinor/")
def next_minor():
    data = request.get_json(force=True) or {}
    print(data)
    uid = data.get("uid", "")
    if not uid:
        abort(400, description="Missing 'uid' query parameter")

    with Session(engine) as s:
        # Ensure user exists
        user = s.scalars(select(Users).where(Users.uid == uid)).first()
        if not user:
            abort(404, description="User not found")

        # Find the largest existing minor for this user’s major
        result = s.execute(
            select(TrackerDevice.beacon_minor)
            .where(TrackerDevice.beacon_major == user.major)
            .order_by(TrackerDevice.beacon_minor.desc())
        ).first()

        next_minor = (result[0] + 1) if result else 1
        return {"major": user.major, "nextMinor": next_minor}
@app.get("/devices")
def list_devices():
    
    with Session(engine) as s:
        rows = s.scalars(select(TrackerDevice).order_by(TrackerDevice.paired_at.desc())).all()
        print([d.to_dict() for d in rows])
        return jsonify([d.to_dict() for d in rows])

@app.post("/devices")
def create_device():
    
    data = request.get_json(force=True) or {}

    # Accept UUID string; generate if missing (to match Swift bleId: UUID)
    ble_id = data.get("bleId") or str(uuid.uuid4())
    name = data.get("name", "")
    owner_uid = data.get("ownerUID", "")
    beacon_major = int(data.get("beaconMajor", 0))
    beacon_minor = int(data.get("beaconMinor", 0))

    now = datetime.now(timezone.utc)

    dev = TrackerDevice(
        ble_id=ble_id,
        name=name,
        owner_uid=owner_uid,
        paired_at=now,
        is_active=bool(data.get("isActive", True)),
        last_seen_at=parse_iso_datetime(data["lastSeenAt"]) if data.get("lastSeenAt") else None,
        last_rssi=int(data["lastRSSI"]) if data.get("lastRSSI") is not None else None,
        last_battery_percent=int(data["lastBatteryPercent"]) if data.get("lastBatteryPercent") is not None else None,
        beacon_major=beacon_major,
        beacon_minor=beacon_minor,
    )
    with Session(engine) as s:
        # If duplicate ble_id, this will raise on commit
        s.add(dev)
        s.commit()
        s.refresh(dev)
        return dev.to_dict(), 201

@app.post("/deleteDevice/")
def delete_device():
    data = request.get_json(force=True) or {}
    print(data)
    major = data.get("major", "")
    minor = data.get("minor", "")
    if not major or not minor:
        abort(400, description="Missing 'major' or 'minor' in request body")
    with Session(engine) as s:
        dev = s.scalars(
            select(TrackerDevice).where(
                (TrackerDevice.beacon_major == int(major)) &
                (TrackerDevice.beacon_minor == int(minor))
            )
        ).first()
        if not dev:
            abort(404, description="Device not found")
        s.delete(dev)
        s.commit()
        return {"message": "Device deleted"}


@app.post("/devices/pings")
def create_ping():
    
    data = request.get_json(force=True) or {}
    print(data)
    major = data.get("major", "")
    minor = data.get("minor", "")
    newlat= data.get("lat", None)
    newlng= data.get("lng", None)
    safe=data.get("last_RSSI", 1)
    ts  = datetime.now(timezone.utc)
    with Session(engine) as s:
        dev = s.execute(
            select(TrackerDevice).where(
                (TrackerDevice.beacon_major == int(major)) &
                (TrackerDevice.beacon_minor == int(minor))
            )
        ).scalar_one_or_none()
        if not dev: abort(404)
       
        # Update device "last seen" convenience fields (optional)
        dev.last_seen_at = ts
        dev.lat=float(newlat)
        dev.lng=float(newlng)
        dev.last_rssi = int(safe)

        s.commit()
        return dev.to_dict(), 201

@app.post("/updateRSSI/")
def update_rssi():
    data = request.get_json(force=True) or {}
    print(data)
    major = data.get("major", "")
    minor = data.get("minor", "")
    rssi = data.get("rssi", "")
    if not major or not minor or rssi=="":
        abort(400, description="Missing 'major', 'minor', 'rssi' in request body")
    with Session(engine) as s:
        dev = s.scalars(
            select(TrackerDevice).where(
                (TrackerDevice.beacon_major == int(major)) &
                (TrackerDevice.beacon_minor == int(minor))
            )
        ).first()
        if not dev:
            abort(404, description="Device not found")
        dev.last_rssi = int(rssi)
        dev.last_seen_at = datetime.now(timezone.utc)
        s.commit()
        return dev.to_dict()

if __name__ == "__main__":
    # For dev only; use a real WSGI server in prod (gunicorn/uvicorn)
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "3000")), debug=True)
