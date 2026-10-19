import CoreGraphics
import Foundation

/// Writes a .pptx with one full-bleed picture per slide.
public enum PPTXWriter {
    private static let emuPerPoint = 12700.0
    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
    ]

    public static func write(slideImages: [URL], slideSize: CGSize, to: URL) async throws {
        guard !slideImages.isEmpty else { throw OrbitError.unsupported("There are no slides to write.") }
        guard slideSize.width > 0, slideSize.height > 0 else { throw OrbitError.unsupported("The slide size is empty.") }
        let exts = try slideImages.map { url -> String in
            let ext = url.pathExtension.lowercased()
            guard imageTypes[ext] != nil else {
                throw OrbitError.unsupported("\(url.lastPathComponent) can't go on a slide. Use PNG, JPEG or GIF.")
            }
            return ext
        }
        let cx = Int((slideSize.width * emuPerPoint).rounded())
        let cy = Int((slideSize.height * emuPerPoint).rounded())

        let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let emptyTree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
        let decl = XMLText.declaration

        var types = "\(decl)<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        types += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        types += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for ext in Set(exts).sorted() { types += "<Default Extension=\"\(ext)\" ContentType=\"\(imageTypes[ext]!)\"/>" }
        let pml = "application/vnd.openxmlformats-officedocument.presentationml"
        types += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(pml).presentation.main+xml\"/>"
        types += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(pml).slideMaster+xml\"/>"
        types += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"\(pml).slideLayout+xml\"/>"
        types += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for i in 1...slideImages.count {
            types += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"\(pml).slide+xml\"/>"
        }
        types += "</Types>"

        let rootRels = "\(decl)<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"\(relType)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>"

        var slideIds = "", presRels = "\(decl)<Relationships xmlns=\"\(relNS)\">"
        presRels += "<Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        presRels += "<Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"theme/theme1.xml\"/>"
        for i in 1...slideImages.count {
            slideIds += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(2 + i)\"/>"
            presRels += "<Relationship Id=\"rId\(2 + i)\" Type=\"\(relType)/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        presRels += "</Relationships>"
        let presentation = "\(decl)<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
            + "<p:sldIdLst>\(slideIds)</p:sldIdLst><p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"

        let master = "\(decl)<p:sldMaster \(ns)><p:cSld><p:spTree>\(emptyTree)</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" "
            + "accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"
        let masterRels = "\(decl)<Relationships xmlns=\"\(relNS)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(relType)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>"
        let layout = "\(decl)<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(emptyTree)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        let layoutRels = "\(decl)<Relationships xmlns=\"\(relNS)\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"

        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("ppt/presentation.xml", Data(presentation.utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presRels.utf8)),
            ("ppt/slideMasters/slideMaster1.xml", Data(master.utf8)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(masterRels.utf8)),
            ("ppt/slideLayouts/slideLayout1.xml", Data(layout.utf8)),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(layoutRels.utf8)),
            ("ppt/theme/theme1.xml", Data(theme.utf8)),
        ]
        for (index, url) in slideImages.enumerated() {
            let n = index + 1
            let media = "image\(n).\(exts[index])"
            let slide = "\(decl)<p:sld \(ns)><p:cSld><p:spTree>\(emptyTree)"
                + "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Picture \(n)\" descr=\"\(XMLText.escape(url.lastPathComponent))\"/>"
                + "<p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
                + "<p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
                + "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
                + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            let slideRels = "\(decl)<Relationships xmlns=\"\(relNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relType)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(relType)/image\" Target=\"../media/\(media)\"/></Relationships>"
            entries.append(("ppt/slides/slide\(n).xml", Data(slide.utf8)))
            entries.append(("ppt/slides/_rels/slide\(n).xml.rels", Data(slideRels.utf8)))
            entries.append(("ppt/media/\(media)", try Data(contentsOf: url)))
        }
        try await ZipPackager.package(entries: entries, to: to)
    }

    /// A complete default Office theme; PowerPoint rejects themes missing any of these sections.
    private static let theme: String = {
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(fill)<a:prstDash val=\"solid\"/></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        return XMLText.declaration
            + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Orbit\"><a:themeElements>"
            + "<a:clrScheme name=\"Orbit\"><a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1>"
            + "<a:dk2><a:srgbClr val=\"44546A\"/></a:dk2><a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>"
            + "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1><a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2>"
            + "<a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3><a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>"
            + "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5><a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6>"
            + "<a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink></a:clrScheme>"
            + "<a:fontScheme name=\"Orbit\"><a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
            + "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
            + "<a:fmtScheme name=\"Orbit\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst>"
            + "<a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme>"
            + "</a:themeElements></a:theme>"
    }()
}
