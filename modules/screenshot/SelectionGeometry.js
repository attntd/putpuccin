.pragma library

// All input and output rectangles use logical coordinates local to one monitor.
// Captured pixel dimensions are used only for the displayed export dimensions.
function clamp(value, lower, upper) {
    return Math.max(lower, Math.min(upper, value));
}

function fromPoints(startX, startY, endX, endY, width, height) {
    const left = clamp(Math.min(startX, endX), 0, width);
    const top = clamp(Math.min(startY, endY), 0, height);
    const right = clamp(Math.max(startX, endX), 0, width);
    const bottom = clamp(Math.max(startY, endY), 0, height);
    return { x: left, y: top, width: right - left, height: bottom - top };
}

function clipped(rect, width, height) {
    if (!rect || !isFinite(rect.x) || !isFinite(rect.y)
            || !isFinite(rect.width) || !isFinite(rect.height)
            || rect.width <= 0 || rect.height <= 0)
        return { x: 0, y: 0, width: 0, height: 0 };
    return fromPoints(rect.x, rect.y, rect.x + rect.width,
        rect.y + rect.height, width, height);
}

function contains(rect, x, y) {
    return rect && rect.width > 0 && rect.height > 0
        && x >= rect.x && y >= rect.y
        && x < rect.x + rect.width && y < rect.y + rect.height;
}

function hitWindow(windows, x, y) {
    // The controller supplies compositor stacking order, frontmost first.
    for (let index = 0; index < windows.length; index++) {
        if (contains(windows[index], x, y))
            return windows[index];
    }
    return null;
}

function adjust(rect, dx, dy, resize, width, height) {
    const current = clipped(rect, width, height);
    if (current.width <= 0 || current.height <= 0) {
        current.width = Math.max(1, Math.floor(width / 2));
        current.height = Math.max(1, Math.floor(height / 2));
        current.x = Math.floor((width - current.width) / 2);
        current.y = Math.floor((height - current.height) / 2);
    }
    if (resize) {
        current.width = clamp(current.width + dx, 1, width - current.x);
        current.height = clamp(current.height + dy, 1, height - current.y);
    } else {
        current.x = clamp(current.x + dx, 0, width - current.width);
        current.y = clamp(current.y + dy, 0, height - current.height);
    }
    return current;
}

function pixels(rect, screen) {
    const scaleX = screen.pixelWidth / screen.width;
    const scaleY = screen.pixelHeight / screen.height;
    return {
        width: Math.max(0, Math.ceil((rect.x + rect.width) * scaleX) - Math.floor(rect.x * scaleX)),
        height: Math.max(0, Math.ceil((rect.y + rect.height) * scaleY) - Math.floor(rect.y * scaleY))
    };
}

function toolbarPosition(rect, panelWidth, panelHeight, width, height, gap) {
    const x = clamp(rect ? rect.x + rect.width / 2 - panelWidth / 2 : (width - panelWidth) / 2,
        gap, Math.max(gap, width - panelWidth - gap));
    let y = height - panelHeight - gap;
    if (rect && rect.y + rect.height + gap + panelHeight <= height - gap)
        y = rect.y + rect.height + gap;
    else if (rect && rect.y - gap - panelHeight >= gap)
        y = rect.y - gap - panelHeight;
    return { x: x, y: Math.max(gap, y) };
}
