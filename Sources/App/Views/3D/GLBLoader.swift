import Foundation
import SceneKit

/// Minimal dependency-free GLB (binary glTF 2.0) reader that rebuilds the node
/// tree in SceneKit.
///
/// Covers exactly the subset the Axo export uses: float POSITION/NORMAL
/// accessors, ushort/uint index buffers, TRS + matrix node transforms, named
/// nodes, `pbrMetallicRoughness` materials, and `KHR_materials_unlit`. No
/// skins, no animations, no texture images — the model is flat-colour PBR, so
/// the whole loader stays in this one file with zero external dependencies.
enum GLBLoader {

    enum GLBError: LocalizedError {
        case truncated, badMagic, badChunk, malformed

        var errorDescription: String? {
            switch self {
            case .truncated: return "The GLB file is truncated."
            case .badMagic: return "Not a GLB file."
            case .badChunk: return "Unexpected GLB chunk layout."
            case .malformed: return "The GLB's JSON section is malformed."
            }
        }
    }

    // MARK: - Entry point

    /// Loads the file and returns the scene-root node holding the full model.
    static func loadNodeTree(from url: URL) throws -> SCNNode {
        let data = try Data(contentsOf: url)
        guard data.count > 20 else { throw GLBError.truncated }

        let magic = data.subdata(in: 0..<4)
        guard magic == Data([0x67, 0x6C, 0x54, 0x46]) else { throw GLBError.badMagic } // "glTF"

        func u32(_ range: Range<Int>) -> UInt32 {
            data.subdata(in: range).withUnsafeBytes { $0.load(as: UInt32.self) }
        }

        let jsonLength = Int(u32(12..<16))
        let jsonType = u32(16..<20)
        guard jsonType == 0x4E4F534A else { throw GLBError.badChunk } // "JSON"
        let jsonData = data.subdata(in: 20..<(20 + jsonLength))
        guard let json = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            throw GLBError.malformed
        }

        // Optional binary chunk directly after the JSON chunk.
        var bin = Data()
        let cursor = 20 + jsonLength
        if cursor + 8 <= data.count, u32(cursor + 4..<cursor + 8) == 0x004E4942 { // "BIN\0"
            let binLength = Int(u32(cursor..<cursor + 4))
            bin = data.subdata(in: (cursor + 8)..<min(cursor + 8 + binLength, data.count))
        }

        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let bufferViews = json["bufferViews"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let materials = json["materials"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let sceneNodes = ((json["scenes"] as? [[String: Any]] ?? []).first?["nodes"] as? [Int]) ?? [0]

        var materialCache: [Int: SCNMaterial] = [:]

        // MARK: Accessors

        func componentCount(_ type: String) -> Int {
            switch type {
            case "SCALAR": return 1
            case "VEC2": return 2
            case "VEC3": return 3
            case "VEC4": return 4
            case "MAT4": return 16
            default: return 1
            }
        }

        func readFloats(_ accessorIndex: Int) -> [Float] {
            guard accessorIndex >= 0, accessorIndex < accessors.count,
                  let accessor = accessors[accessorIndex] as [String: Any]?,
                  let count = accessor["count"] as? Int,
                  let type = accessor["type"] as? String,
                  accessor["componentType"] as? Int == 5126 else { return [] }
            let comps = componentCount(type)
            var result = [Float](repeating: 0, count: count * comps)
            var base = 0
            var stride = 0
            if let bvIndex = accessor["bufferView"] as? Int, bvIndex < bufferViews.count,
               let bv = bufferViews[bvIndex] as [String: Any]? {
                base = bv["byteOffset"] as? Int ?? 0
                stride = bv["byteStride"] as? Int ?? 0
            }
            let offset = base + (accessor["byteOffset"] as? Int ?? 0)
            let natural = comps * MemoryLayout<Float>.size
            if stride == 0 || stride == natural {
                guard offset + count * natural <= bin.count else { return result }
                bin.subdata(in: offset..<(offset + count * natural)).withUnsafeBytes { raw in
                    result.withUnsafeMutableBytes { dst in
                        _ = memcpy(dst.baseAddress, raw.baseAddress, count * natural)
                    }
                }
            } else {
                for i in 0..<(count * comps) {
                    let p = offset + (i / comps) * stride + (i % comps) * 4
                    guard p + 4 <= bin.count else { break }
                    result[i] = bin.subdata(in: p..<(p + 4)).withUnsafeBytes { $0.load(as: Float.self) }
                }
            }
            return result
        }

        func readIndices(_ accessorIndex: Int) -> (data: Data, bytesPerIndex: Int, count: Int)? {
            guard accessorIndex >= 0, accessorIndex < accessors.count,
                  let accessor = accessors[accessorIndex] as [String: Any]?,
                  let count = accessor["count"] as? Int,
                  let componentType = accessor["componentType"] as? Int else { return nil }
            let bytesPerIndex: Int
            switch componentType {
            case 5123: bytesPerIndex = 2  // UInt16
            case 5125: bytesPerIndex = 4  // UInt32
            default: return nil
            }
            var base = 0
            if let bvIndex = accessor["bufferView"] as? Int, bvIndex < bufferViews.count,
               let bv = bufferViews[bvIndex] as [String: Any]? {
                base = bv["byteOffset"] as? Int ?? 0
            }
            let offset = base + (accessor["byteOffset"] as? Int ?? 0)
            guard offset + count * bytesPerIndex <= bin.count else { return nil }
            return (bin.subdata(in: offset..<(offset + count * bytesPerIndex)), bytesPerIndex, count)
        }

        // MARK: Materials

        func makeMaterial(_ index: Int) -> SCNMaterial {
            if let cached = materialCache[index] { return cached }
            let mat = SCNMaterial()
            let spec = index < materials.count ? (materials[index] as [String: Any]) : [:]
            let pbr = spec["pbrMetallicRoughness"] as? [String: Any] ?? [:]

            if let c = pbr["baseColorFactor"] as? [Double], c.count >= 3 {
                mat.diffuse.contents = NSColor(
                    red: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]),
                    alpha: c.count > 3 ? CGFloat(c[3]) : 1
                )
            }
            mat.lightingModel = .physicallyBased
            mat.roughness.contents = (pbr["roughnessFactor"] as? Double).map { CGFloat($0) } ?? 0.8
            mat.metalness.contents = (pbr["metallicFactor"] as? Double).map { CGFloat($0) } ?? 0.0
            if let e = spec["emissiveFactor"] as? [Double], e.count >= 3, e.reduce(0, +) > 0.001 {
                mat.emission.contents = NSColor(red: CGFloat(e[0]), green: CGFloat(e[1]),
                                                blue: CGFloat(e[2]), alpha: 1)
            }
            if (spec["extensions"] as? [String: Any])?["KHR_materials_unlit"] != nil {
                mat.lightingModel = .constant
            }
            // Three.js exports can carry flipped winding on scaled primitives;
            // double-sided keeps every shell visible without winding audits.
            mat.isDoubleSided = true
            materialCache[index] = mat
            return mat
        }

        // MARK: Geometry

        func makeGeometry(_ primitive: [String: Any]) -> SCNGeometry? {
            guard let attributes = primitive["attributes"] as? [String: Any],
                  let positionIndex = attributes["POSITION"] as? Int else { return nil }
            let positions = readFloats(positionIndex)
            let vertexCount = positions.count / 3
            guard vertexCount > 0 else { return nil }

            var sources: [SCNGeometrySource] = []
            sources.append(SCNGeometrySource(
                data: positions.withUnsafeBufferPointer { Data(buffer: $0) },
                semantic: .vertex, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: 4, dataOffset: 0, dataStride: 12
            ))

            if let normalIndex = attributes["NORMAL"] as? Int {
                let normals = readFloats(normalIndex)
                if normals.count == vertexCount * 3 {
                    sources.append(SCNGeometrySource(
                        data: normals.withUnsafeBufferPointer { Data(buffer: $0) },
                        semantic: .normal, vectorCount: vertexCount,
                        usesFloatComponents: true, componentsPerVector: 3,
                        bytesPerComponent: 4, dataOffset: 0, dataStride: 12
                    ))
                }
            } else {
                sources.append(smoothNormals(positions: positions, vertexCount: vertexCount))
            }

            let indices = (primitive["indices"] as? Int).flatMap { readIndices($0) }
            let element: SCNGeometryElement
            if let indices {
                element = SCNGeometryElement(
                    data: indices.data, primitiveType: .triangles,
                    primitiveCount: indices.count / 3, bytesPerIndex: indices.bytesPerIndex
                )
            } else {
                let sequential = [UInt32](0..<UInt32(vertexCount))
                element = SCNGeometryElement(
                    data: sequential.withUnsafeBufferPointer { Data(buffer: $0) },
                    primitiveType: .triangles, primitiveCount: vertexCount / 3, bytesPerIndex: 4
                )
            }
            return SCNGeometry(sources: sources, elements: [element])
        }

        /// Face-average smooth normals for exports that omit the NORMAL attribute.
        func smoothNormals(positions: [Float], vertexCount: Int) -> SCNGeometrySource {
            var accumulated = [SIMD3<Float>](repeating: .zero, count: vertexCount)
            var i = 0
            while i + 2 < vertexCount {
                let a = SIMD3<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2])
                let b = SIMD3<Float>(positions[i * 3 + 3], positions[i * 3 + 4], positions[i * 3 + 5])
                let c = SIMD3<Float>(positions[i * 3 + 6], positions[i * 3 + 7], positions[i * 3 + 8])
                let n = simd_cross(b - a, c - a)
                accumulated[i] += n; accumulated[i + 1] += n; accumulated[i + 2] += n
                i += 3
            }
            var normals = [Float](repeating: 0, count: vertexCount * 3)
            for v in 0..<vertexCount {
                var n = accumulated[v]
                if simd_length(n) < 1e-9 { n = SIMD3<Float>(0, 1, 0) }
                n = simd_normalize(n)
                normals[v * 3] = n.x; normals[v * 3 + 1] = n.y; normals[v * 3 + 2] = n.z
            }
            return SCNGeometrySource(
                data: normals.withUnsafeBufferPointer { Data(buffer: $0) },
                semantic: .normal, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3,
                bytesPerComponent: 4, dataOffset: 0, dataStride: 12
            )
        }

        // MARK: Node tree

        func buildNode(_ index: Int) -> SCNNode {
            let node = index < nodes.count ? (nodes[index] as [String: Any]) : [:]
            let scn = SCNNode()
            if let name = node["name"] as? String { scn.name = name }

            if let m = node["matrix"] as? [Double], m.count == 16 {
                // glTF stores column-major (column-vector) matrices; SceneKit is
                // row-vector (translation lives in m41..m43). The correct mapping
                // is therefore the transpose: the array fills m11...m44 in order.
                scn.transform = SCNMatrix4(
                    m11: CGFloat(m[0]), m12: CGFloat(m[1]), m13: CGFloat(m[2]), m14: CGFloat(m[3]),
                    m21: CGFloat(m[4]), m22: CGFloat(m[5]), m23: CGFloat(m[6]), m24: CGFloat(m[7]),
                    m31: CGFloat(m[8]), m32: CGFloat(m[9]), m33: CGFloat(m[10]), m34: CGFloat(m[11]),
                    m41: CGFloat(m[12]), m42: CGFloat(m[13]), m43: CGFloat(m[14]), m44: CGFloat(m[15])
                )
            } else {
                if let t = node["translation"] as? [Double], t.count >= 3 {
                    scn.position = SCNVector3(t[0], t[1], t[2])
                }
                if let r = node["rotation"] as? [Double], r.count >= 4 {
                    // glTF stores [x, y, z, w]; simd_quatf takes the real part last.
                    scn.simdOrientation = simd_quatf(ix: Float(r[0]), iy: Float(r[1]),
                                                     iz: Float(r[2]), r: Float(r[3]))
                }
                if let s = node["scale"] as? [Double], s.count >= 3 {
                    scn.simdScale = simd_float3(Float(s[0]), Float(s[1]), Float(s[2]))
                }
            }

            if let meshIndex = node["mesh"] as? Int, meshIndex < meshes.count,
               let mesh = meshes[meshIndex] as [String: Any]?,
               let primitives = mesh["primitives"] as? [[String: Any]] {
                for primitive in primitives {
                    guard let geometry = makeGeometry(primitive) else { continue }
                    if let materialIndex = primitive["material"] as? Int {
                        geometry.materials = [makeMaterial(materialIndex)]
                    }
                    // One child node per primitive keeps multi-material meshes intact.
                    let meshNode = SCNNode(geometry: geometry)
                    scn.addChildNode(meshNode)
                }
            }

            if let children = node["children"] as? [Int] {
                for child in children {
                    guard child != index else { continue }  // never self-parent
                    scn.addChildNode(buildNode(child))
                }
            }
            return scn
        }

        let root = SCNNode()
        root.name = "GLB_Root"
        for sceneNode in sceneNodes {
            root.addChildNode(buildNode(sceneNode))
        }
        return root
    }
}
