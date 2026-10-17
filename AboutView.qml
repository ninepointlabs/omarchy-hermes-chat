import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "About.js" as About

// The dropdown's About page: who made Hermes Chat, its version and license,
// where to get help, and what it does with your data. Panel.qml swaps it in
// for the chat (the info button in the header); Back or Esc returns.
Column {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property bool showLicense: false
  property string notice: ""

  signal backRequested()

  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property real labelWidth: Style.space(72)
  readonly property real valueWidth: width - labelWidth - Style.space(12)

  // This plugin's own folder, wherever it is installed.
  readonly property string pluginDir: {
    var text = String(Qt.resolvedUrl("."))
    if (text.indexOf("file://") === 0) text = decodeURIComponent(text.substring(7))
    return text.length > 1 && text.charAt(text.length - 1) === "/" ? text.substring(0, text.length - 1) : text
  }
  readonly property string version: About.manifestVersion(manifestFile.loaded ? manifestFile.text() : "")
  readonly property string quickshellVersion: About.probedVersion(function(a, b) { return Quickshell.hasVersion(a, b) }, 0)
  readonly property string qtVersion: About.probedVersion(function(a, b) { return Quickshell.hasQtVersion(a, b) }, 6)
  readonly property string details: About.details(root.version, root.quickshellVersion, root.qtVersion,
    (Quickshell.env("XDG_CURRENT_DESKTOP") || "unknown desktop") + ", " + Qt.platform.pluginName)

  function copy(text, what) {
    Quickshell.clipboardText = text
    root.notice = what + " copied"
    noticeTimer.restart()
  }

  spacing: Style.space(12)
  onVisibleChanged: if (!visible) { root.showLicense = false; root.notice = "" }

  // Read only while the page is showing.
  FileView { id: manifestFile; path: root.visible ? root.pluginDir + "/manifest.json" : ""; printErrors: false }
  FileView { id: licenseFile; path: root.visible ? root.pluginDir + "/LICENSE" : ""; printErrors: false }

  Timer { id: noticeTimer; interval: 2500; onTriggered: root.notice = "" }

  Item {
    width: parent.width
    height: Math.max(heading.implicitHeight, backButton.implicitHeight)

    Row {
      id: heading
      anchors.left: parent.left
      anchors.right: backButton.left
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(14)

      ChatIcon {
        id: appIcon
        iconSize: Style.font.display * 1.5
        color: root.accent
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - appIcon.width - parent.spacing
        spacing: Style.space(3)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: About.NAME
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: About.TAGLINE
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          objectName: "aboutVersion"
          text: "Version " + (root.version || "unknown")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    PanelActionButton {
      id: backButton
      objectName: "aboutBack"
      anchors.right: parent.right
      anchors.top: parent.top
      iconText: "󰁍"
      tooltipText: "Back (Esc)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.backRequested()
    }
  }

  PanelSeparator { foreground: root.foreground }

  Grid {
    width: parent.width
    columns: 2
    columnSpacing: Style.space(12)
    rowSpacing: Style.space(8)

    Text { width: root.labelWidth; text: "Made by"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { width: root.valueWidth; text: About.ORGANIZATION; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

    Text { width: root.labelWidth; text: "Created"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text { width: root.valueWidth; text: About.CREATED; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }

    Text { width: root.labelWidth; text: "License"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Column {
      width: root.valueWidth
      spacing: Style.space(4)
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: licenseFile.loaded ? About.licenseSummary(licenseFile.text()) : "MIT License"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        objectName: "aboutLicense"
        text: root.showLicense ? "Hide license" : "Read license"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.showLicense = !root.showLicense
      }
    }

    Text { width: root.labelWidth; text: "Support"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Column {
      width: root.valueWidth
      spacing: Style.space(4)
      Text {
        text: About.SUPPORT_EMAIL
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        Button {
          objectName: "aboutEmail"
          text: "Email"
          tooltipText: "Opens your mail app with the version details filled in"
          bordered: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: Qt.openUrlExternally(About.mailto(root.version, root.details))
        }
        Button {
          objectName: "aboutCopyEmail"
          text: "Copy"
          bordered: true
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          onClicked: root.copy(About.SUPPORT_EMAIL, "Address")
        }
      }
    }

    Text { width: root.labelWidth; text: "Built with"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
    Text {
      width: root.valueWidth
      wrapMode: Text.WordWrap
      text: About.builtWith(root.quickshellVersion, root.qtVersion)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  Text {
    width: parent.width
    text: "PRIVACY"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }
  Text {
    objectName: "aboutPrivacy"
    width: parent.width
    wrapMode: Text.WordWrap
    text: About.PRIVACY
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Text {
    objectName: "aboutLicenseText"
    visible: root.showLicense
    width: parent.width
    wrapMode: Text.WordWrap
    text: licenseFile.loaded ? About.licenseBody(licenseFile.text()) : "LICENSE could not be read from the plugin folder."
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    width: parent.width
    spacing: Style.space(8)
    layoutDirection: Qt.RightToLeft

    Button {
      objectName: "aboutCopyDetails"
      text: "Copy version details"
      bordered: true
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: root.copy(root.details, "Version details")
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.notice
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
