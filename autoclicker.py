import time
import threading
import select
from evdev import InputDevice, UInput, list_devices, ecodes as e

# ==========================================
#               SETTINGS
# ==========================================
CPS = 1000                        # Target Clicks Per Second
CLICK_BUTTON = e.BTN_LEFT         # Button to click (e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE)
TARGET_KEY = e.KEY_F8             # The key you must HOLD down to click
# ==========================================

is_clicking = False
exit_flag = False

def clicker_thread(ui):
    """This thread runs continuously and fires clicks when the flag is True."""
    global is_clicking, exit_flag

    sleep_time = 1.0 / CPS

    while not exit_flag:
        if is_clicking:
            ui.write(e.EV_KEY, CLICK_BUTTON, 1) # Mouse down
            ui.syn()                            # Commit
            ui.write(e.EV_KEY, CLICK_BUTTON, 0) # Mouse up
            ui.syn()                            # Commit
            time.sleep(sleep_time)
        else:
            time.sleep(0.01)

def main():
    global is_clicking, exit_flag

    # 1. Scan all connected devices
    try:
        devices = [InputDevice(path) for path in list_devices()]
    except PermissionError:
        print("ERROR: You must run this script with sudo!")
        return

    # 2. Filter for devices that actually have the target key
    listening_devices = []
    for device in devices:
        caps = device.capabilities()
        if e.EV_KEY in caps and TARGET_KEY in caps[e.EV_KEY]:
            listening_devices.append(device)

    if not listening_devices:
        print(f"ERROR: No device found that supports the keycode {TARGET_KEY}.")
        return

    print("Found the following compatible devices:")
    for dev in listening_devices:
        print(f" - {dev.name} ({dev.path})")

    # 3. Create the virtual mouse
    cap = { e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE] }

    with UInput(cap, name='wayland-autoclicker') as ui:
        t = threading.Thread(target=clicker_thread, args=(ui,))
        t.start()

        print(f"\n[READY] HOLD down the target key to click at {CPS} CPS.")
        print("Press Ctrl+C in this terminal to exit.\n")

        try:
            # 4. Listen to all compatible devices at the same time
            while True:
                # select.select waits until one of the devices has a new event
                r, w, x = select.select(listening_devices, [], [], 0.1)
                for dev in r:
                    for event in dev.read():
                        if event.type == e.EV_KEY and event.code == TARGET_KEY:
                            if event.value == 1:   # Key pressed
                                is_clicking = True
                            elif event.value == 0: # Key released
                                is_clicking = False
        except KeyboardInterrupt:
            print("\nShutting down autoclicker...")
            exit_flag = True
            t.join()

if __name__ == "__main__":
    main()
