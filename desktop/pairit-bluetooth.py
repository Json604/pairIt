"""Expose the running desktop companion's pinned TLS listener over Bluetooth Classic."""
import socket
import sys
import threading
from contextlib import suppress

SERVICE = "71f55b60-e473-4c78-a90b-ec41d2f86c11"
MAX_PEERS = 4


class Connections:
    def __init__(self):
        self.peers = {}
        self.lock = threading.Lock()

    def accept(self, device, radio):
        local = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with self.lock:
            if device in self.peers or len(self.peers) >= MAX_PEERS:
                radio.close()
                local.close()
                return
            self.peers[device] = (radio, local)
        threading.Thread(target=self.relay, args=(device, radio, local), daemon=True).start()

    def close(self, device, radio=None):
        with self.lock:
            pair = self.peers.get(device)
            if not pair or (radio is not None and pair[0] is not radio):
                return
            del self.peers[device]
        for stream in pair:
            with suppress(OSError):
                stream.shutdown(socket.SHUT_RDWR)
            stream.close()

    def relay(self, device, radio, local):
        def copy(source, destination):
            try:
                while data := source.recv(16384):
                    destination.sendall(data)
            except OSError:
                pass
            finally:
                self.close(device, radio)

        try:
            local.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            local.connect(("127.0.0.1", 5002))
            radio.setblocking(True)
            threading.Thread(target=copy, args=(radio, local), daemon=True).start()
            copy(local, radio)
        except OSError:
            self.close(device, radio)


def windows_service(listener, register):
    # Winsock builds the SDP record from the bound channel and service class.
    import ctypes as c
    from ctypes import wintypes as w
    import uuid

    class Address(c.Structure):
        _fields_ = [("data", c.c_void_p), ("length", c.c_int)]

    class CsAddr(c.Structure):
        _fields_ = [("local", Address), ("remote", Address),
                    ("kind", c.c_int), ("protocol", c.c_int)]

    class Query(c.Structure):
        _fields_ = [("size", w.DWORD), ("name", w.LPWSTR), ("service", c.c_void_p),
                    ("version", c.c_void_p), ("comment", w.LPWSTR), ("namespace", w.DWORD),
                    ("provider", c.c_void_p), ("context", w.LPWSTR), ("protocol_count", w.DWORD),
                    ("protocols", c.c_void_p), ("query", w.LPWSTR), ("address_count", w.DWORD),
                    ("addresses", c.POINTER(CsAddr)), ("flags", w.DWORD), ("blob", c.c_void_p)]

    ws = c.WinDLL("ws2_32")
    bound = c.create_string_buffer(128)
    length = c.c_int(c.sizeof(bound))
    if ws.getsockname(c.c_size_t(listener.fileno()), bound, c.byref(length)):
        raise c.WinError(ws.WSAGetLastError())
    service = c.create_string_buffer(uuid.UUID(SERVICE).bytes_le)
    addr = CsAddr(Address(c.addressof(bound), length.value), Address(), socket.SOCK_STREAM, 3)
    entry = Query(size=c.sizeof(Query), name="PairIt Audio", service=c.addressof(service),
                  namespace=16, address_count=1, addresses=c.pointer(addr))
    if ws.WSASetServiceW(c.byref(entry), 0 if register else 2, 0):
        raise c.WinError(ws.WSAGetLastError())


def windows(peers):
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM) as server:
        # SOL_RFCOMM / SO_BTH_AUTHENTICATE and SO_BTH_ENCRYPT from ws2bth.h
        for option in (-2147483647, 2):
            server.setsockopt(3, option, 1)
        server.bind(("00:00:00:00:00:00", getattr(socket, "BT_PORT_ANY", 0xffffffff)))
        server.listen(MAX_PEERS)
        windows_service(server, True)
        try:
            print("PairIt Bluetooth is ready. Keep this window open.", flush=True)
            while True:
                radio, address = server.accept()
                peers.accept(address[0], radio)
        finally:
            windows_service(server, False)


def linux(peers):
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    bus = dbus.SystemBus()
    path = "/org/pairit/AudioProfile"
    interface = "org.bluez.Profile1"

    class Profile(dbus.service.Object):
        @dbus.service.method(interface, in_signature="", out_signature="")
        def Release(self):
            loop.quit()

        @dbus.service.method(interface, in_signature="oha{sv}", out_signature="")
        def NewConnection(self, device, fd, properties):
            peers.accept(str(device), socket.socket(fileno=fd.take()))

        @dbus.service.method(interface, in_signature="o", out_signature="")
        def RequestDisconnection(self, device):
            peers.close(str(device))

    profile = Profile(bus, path)
    manager = dbus.Interface(bus.get_object("org.bluez", "/org/bluez"), "org.bluez.ProfileManager1")
    manager.RegisterProfile(path, SERVICE, {"Name": "PairIt Audio", "Role": "server",
                                            "Channel": dbus.UInt16(0), "RequireAuthentication": True})
    try:
        print("PairIt Bluetooth is ready. Keep this terminal open.", flush=True)
        loop.run()
    finally:
        with suppress(dbus.DBusException):
            manager.UnregisterProfile(path)
        profile.remove_from_connection()


if __name__ == "__main__":
    try:
        if sys.platform == "win32":
            windows(Connections())
        elif sys.platform.startswith("linux"):
            linux(Connections())
        else:
            sys.exit("Use the Bluetooth option in the Mac companion.")
    except KeyboardInterrupt:
        pass
    except (ImportError, OSError) as error:
        sys.exit(f"Could not start PairIt Bluetooth: {error}")
