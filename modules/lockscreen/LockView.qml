import QtQuick
import qs.components
import qs.core

SessionAuthView {
    inputEnabled: auth.secure
    avatarSource: "file://" + Settings.lockAvatarPath
}
