import QtQuick
import QtQuick.Window
import QtQuick.Templates as T

// Event-driven navigation within one panel. Text editors keep native input;
// lists keep their virtualized model and sliders use their existing commands.
Item {
    id: root
    required property Item scope

    function focusedItem() { return scope.Window.activeFocusItem; }

    function contains(item, ancestor) {
        for (let current = item; current; current = current.parent)
            if (current === ancestor) return true;
        return false;
    }

    function isEditor(item) {
        return item instanceof TextInput || item instanceof TextEdit;
    }

    function collect(item, result) {
        if (!item.visible || !item.enabled) return;
        // Enter editors explicitly with Tab, a click, or the panel's search key.
        if (isEditor(item)) return;
        if (item !== scope && item.activeFocusOnTab && item.width > 0 && item.height > 0)
            result.push(item);
        if (item instanceof ListView && item.activeFocusOnTab) return;
        for (const child of item.children) collect(child, result);
    }

    function controls() {
        const result = [];
        collect(scope, result);
        return result;
    }

    function focusFirst() {
        const items = controls();
        const item = items.length ? items[0] : scope;
        item.forceActiveFocus(Qt.TabFocusReason);
        // Qt can preserve OtherFocusReason when the control was already
        // focused during native activation. Updating the public reason makes
        // that first selection visible without an extra Tab key.
        if (item instanceof T.Control) item.focusReason = Qt.TabFocusReason;
    }

    function rect(item) {
        const origin = item.mapToItem(scope, 0, 0);
        return {x: origin.x, y: origin.y, width: item.width, height: item.height};
    }

    function move(horizontal, direction) {
        const items = controls();
        const focused = focusedItem();
        let current = focused;
        while (current && current !== scope && items.indexOf(current) < 0)
            current = current.parent;
        if (!current || current === scope) {
            focusFirst();
            return;
        }
        if (!horizontal && current instanceof ListView) {
            const index = current.currentIndex + direction;
            if (index >= 0 && index < current.count) {
                current.currentIndex = index;
                current.positionViewAtIndex(index, ListView.Contain);
                return;
            }
        }
        if (horizontal && current instanceof T.Slider) {
            const previous = current.value;
            // Native methods preserve the binding to the service's live value.
            if (direction > 0) current.increase();
            else current.decrease();
            if (current.value !== previous) current.moved();
            return;
        }
        const from = rect(current);
        let best = null, bestScore = Infinity;
        for (const candidate of items) {
            if (candidate === current || contains(current, candidate)) continue;
            const to = rect(candidate);
            const along = horizontal
                ? (to.x + to.width / 2 - from.x - from.width / 2) * direction
                : (to.y + to.height / 2 - from.y - from.height / 2) * direction;
            if (along <= 1) continue;
            const overlap = horizontal
                ? Math.min(from.y + from.height, to.y + to.height) - Math.max(from.y, to.y)
                : Math.min(from.x + from.width, to.x + to.width) - Math.max(from.x, to.x);
            // Left/right stays in the row. Up/down prefers the same column.
            if (horizontal && overlap <= 0) continue;
            const across = horizontal ? Math.abs(to.y - from.y)
                : Math.abs(to.x + to.width / 2 - from.x - from.width / 2);
            const score = along + across / 4 + (overlap <= 0 ? 10000 : 0);
            if (score < bestScore) { best = candidate; bestScore = score; }
        }
        if (best) {
            best.forceActiveFocus(direction > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason);
            if (best instanceof ListView && best.count > 0) {
                best.currentIndex = direction > 0 ? 0 : best.count - 1;
                best.positionViewAtIndex(best.currentIndex, ListView.Contain);
            }
        }
    }

    function handleKey(event) {
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        const focused = focusedItem();
        if (!contains(focused, scope) || isEditor(focused)) return;
        const key = event.key;
        if (key === Qt.Key_H || key === Qt.Key_Left) move(true, -1);
        else if (key === Qt.Key_L || key === Qt.Key_Right) move(true, 1);
        else if (key === Qt.Key_J || key === Qt.Key_Down) move(false, 1);
        else if (key === Qt.Key_K || key === Qt.Key_Up) move(false, -1);
        else if ((key === Qt.Key_Return || key === Qt.Key_Enter) && focused instanceof T.AbstractButton) {
            if (!event.isAutoRepeat && focused.enabled) focused.click();
        } else return;
        event.accepted = true;
    }
}
