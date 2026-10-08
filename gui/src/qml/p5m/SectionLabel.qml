import QtQuick

// Small caps section title (SCREEN, STREAM...).
Text {
    color: Theme.textMuted
    font.pixelSize: Theme.sectionSize
    font.weight: Font.Medium
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Theme.sectionSize * 0.14
    topPadding: 20
    bottomPadding: 10
    leftPadding: 6
}
