import CoreGraphics

struct MeetingWorkspaceLayout {
    let containerWidth: CGFloat
    let containerHeight: CGFloat

    var detailAreaWidth: CGFloat {
        max(containerWidth - sidebarWidth, 760)
    }

    var sidebarWidth: CGFloat {
        clamp(containerWidth * 0.34, min: 460, max: 620)
    }

    var detailHorizontalPadding: CGFloat {
        clamp(detailAreaWidth * 0.08, min: 56, max: 108)
    }

    var detailVerticalPadding: CGFloat {
        clamp(containerHeight * 0.04, min: 32, max: 52)
    }

    var sidebarHorizontalPadding: CGFloat {
        clamp(sidebarWidth * 0.06, min: 28, max: 40)
    }

    var sidebarTitleFontSize: CGFloat {
        clamp(sidebarWidth * 0.05, min: 16, max: 22)
    }

    var sidebarBodyFontSize: CGFloat {
        clamp(sidebarWidth * 0.022, min: 9, max: 12)
    }

    var sidebarCardTitleFontSize: CGFloat {
        clamp(sidebarWidth * 0.033, min: 12, max: 16)
    }

    var sidebarCardMetadataFontSize: CGFloat {
        clamp(sidebarWidth * 0.019, min: 9, max: 11)
    }

    var sidebarSectionTitleFontSize: CGFloat {
        clamp(sidebarWidth * 0.024, min: 11, max: 14)
    }

    var detailTitleFontSize: CGFloat {
        clamp(detailAreaWidth * 0.022, min: 16, max: 22)
    }

    var detailMetadataFontSize: CGFloat {
        clamp(detailAreaWidth * 0.0105, min: 9, max: 11)
    }

    var tabFontSize: CGFloat {
        clamp(detailAreaWidth * 0.011, min: 10, max: 12)
    }

    var detailContentMaxWidth: CGFloat {
        clamp(detailAreaWidth - (detailHorizontalPadding * 2), min: 820, max: 1360)
    }

    var playerBarMaxWidth: CGFloat {
        clamp(detailContentMaxWidth, min: 820, max: 1320)
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
