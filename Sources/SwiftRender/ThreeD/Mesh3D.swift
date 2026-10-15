import SceneKit
import simd

/// Builds an `SCNGeometry` from raw triangle data — for procedural meshes.
enum Mesh3D {
    /// - Parameter elements: one index list per material slot (triangles, counter-clockwise
    ///   when seen from outside).
    static func geometry(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>],
                         elements: [[UInt32]]) -> SCNGeometry {
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        let normalData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let stride3 = MemoryLayout<SIMD3<Float>>.stride, stride2 = MemoryLayout<SIMD2<Float>>.stride
        let sources = [
            SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: normalData, semantic: .normal, vectorCount: normals.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride3),
            SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: uvs.count, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: stride2),
        ]
        let els = elements.map { idx in
            SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                               primitiveCount: idx.count / 3, bytesPerIndex: 4)
        }
        return SCNGeometry(sources: sources, elements: els)
    }
}
