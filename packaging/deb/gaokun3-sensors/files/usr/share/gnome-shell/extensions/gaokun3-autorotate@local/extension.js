import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';

const SERVICE = 'gaokun3-auto-rotate.service';
const ICON_ON = 'rotation-allowed-symbolic';
const ICON_OFF = 'rotation-locked-symbolic';

const AutoRotateToggle = GObject.registerClass(
class AutoRotateToggle extends QuickSettings.QuickToggle {
    _init() {
        super._init({
            title: '自动旋转',
            iconName: ICON_OFF,
            checked: false,
        });

        this._unit = null;
        this._active = undefined;
        this._manager = new Gio.DBusProxy({
            g_connection: Gio.DBus.session,
            g_name: 'org.freedesktop.systemd1',
            g_object_path: '/org/freedesktop/systemd1',
            g_interface_name: 'org.freedesktop.systemd1.Manager',
        });
        this._manager.init_async(GLib.PRIORITY_DEFAULT, null, (proxy, res) => {
            try {
                proxy.init_finish(res);
            } catch (e) {
                logError(e, 'auto-rotate: failed to reach systemd');
                return;
            }
            this._watchUnit();
        });

        this.connectObject('clicked', () => this._toggle(), this);
    }

    _watchUnit(attempt = 0) {
        if (!this._manager)
            return;
        this._manager.call('GetUnit', new GLib.Variant('(s)', [SERVICE]),
            Gio.DBusCallFlags.NONE, -1, null, (proxy, res) => {
                let path;
                try {
                    [path] = proxy.call_finish(res).deepUnpack();
                } catch (e) {
                    // The package may be installed after the extension is enabled.
                    if (attempt < 4) {
                        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
                            this._watchUnit(attempt + 1);
                            return GLib.SOURCE_REMOVE;
                        });
                        return;
                    }
                    logError(e, 'auto-rotate: GetUnit failed');
                    return;
                }
                const unit = new Gio.DBusProxy({
                    g_connection: Gio.DBus.session,
                    g_name: 'org.freedesktop.systemd1',
                    g_object_path: path,
                    g_interface_name: 'org.freedesktop.systemd1.Unit',
                });
                unit.init_async(GLib.PRIORITY_DEFAULT, null, (p, r) => {
                    try {
                        p.init_finish(r);
                    } catch (e) {
                        logError(e, 'auto-rotate: failed to watch unit');
                        return;
                    }
                    if (!this._manager) {
                        p.run_dispose();
                        return;
                    }
                    this._unit = p;
                    p.connectObject('g-properties-changed', () => this._sync(), this);
                    this._sync();
                });
            });
    }

    _sync() {
        const state = this._unit?.get_cached_property('ActiveState')?.deepUnpack();
        this._active = state === 'active' || state === 'activating';
        this.checked = this._active;
        this.iconName = this._active ? ICON_ON : ICON_OFF;
    }

    _toggle() {
        if (!this._unit || this._active === undefined)
            return;
        const wantActive = !this._active;
        this._active = wantActive;
        this.checked = wantActive;
        this.iconName = wantActive ? ICON_ON : ICON_OFF;
        try {
            this._manager.call(wantActive ? 'StartUnit' : 'StopUnit',
                new GLib.Variant('(ss)', [SERVICE, 'replace']),
                Gio.DBusCallFlags.NONE, -1, null, () => this._sync());
        } catch (e) {
            logError(e, 'auto-rotate: failed to toggle the daemon');
            this._sync();
        }
    }

    destroy() {
        // The proxies outlive the actor unless they are disposed by hand.
        this._unit?.run_dispose();
        this._unit = null;
        this._manager.run_dispose();
        this._manager = null;
        super.destroy();
    }
});

const AutoRotateIndicator = GObject.registerClass(
class AutoRotateIndicator extends QuickSettings.SystemIndicator {
    _init() {
        super._init();
        this._toggle = new AutoRotateToggle();
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class AutoRotateExtension extends Extension {
    enable() {
        this._indicator = new AutoRotateIndicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
