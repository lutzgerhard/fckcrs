// FCKCRS

import Foundation
import simd
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "VelocityKalmanFilter")

// MARK: - Estimate

struct VelocityKalmanEstimate {
    /// World X position (metres, ARKit convention).
    var px: Double
    /// World Z position (metres, ARKit convention).
    var pz: Double
    /// World X velocity (m/s).
    var vx: Double
    /// World Z velocity (m/s).
    var vz: Double

    /// Scalar ground-plane speed in m/s.
    var speedMS: Double { sqrt(vx * vx + vz * vz) }
}

// MARK: - Per-vehicle state

private struct KalmanState {
    // State vector: [px, pz, vx, vz]
    var x: (Double, Double, Double, Double)   // (px, pz, vx, vz)
    // Error covariance 4×4, stored row-major (16 elements)
    var P: [Double]
    var lastTimestamp: Double
}

// MARK: - VelocityKalmanFilter

/// 4-state constant-velocity Kalman filter in the ARKit XZ ground plane.
/// State: [px, pz, vx, vz].  Observation: [px, pz] (position only).
/// One independent filter instance is maintained per vehicle UUID.
final class VelocityKalmanFilter {

    // MARK: Config

    /// Measurement noise standard deviation for position observations (metres).
    var sigmaPosition: Double = 0.5
    /// Process noise standard deviation for acceleration (CWNA model, m/s²).
    var sigmaAccel: Double = 2.0

    // MARK: Private state

    private var states: [UUID: KalmanState] = [:]

    // MARK: - Public API

    /// Feed a new position measurement and return the filtered estimate.
    @discardableResult
    func update(id: UUID,
                measuredPX: Double,
                measuredPZ: Double,
                timestamp: Double) -> VelocityKalmanEstimate {

        if let existing = states[id] {
            return runFilter(id: id, state: existing,
                             measuredPX: measuredPX, measuredPZ: measuredPZ,
                             timestamp: timestamp)
        } else {
            // Initialise with the measurement; velocity = 0; large uncertainty.
            let P0: [Double] = [
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 9, 0,
                0, 0, 0, 9,
            ]
            let init_state = KalmanState(
                x: (measuredPX, measuredPZ, 0.0, 0.0),
                P: P0,
                lastTimestamp: timestamp
            )
            states[id] = init_state
            return VelocityKalmanEstimate(px: measuredPX, pz: measuredPZ, vx: 0, vz: 0)
        }
    }

    func remove(id: UUID) {
        states.removeValue(forKey: id)
    }

    func clear() {
        states.removeAll()
    }

    // MARK: - Filter internals

    private func runFilter(id: UUID,
                           state: KalmanState,
                           measuredPX: Double,
                           measuredPZ: Double,
                           timestamp: Double) -> VelocityKalmanEstimate {
        let dt = max(timestamp - state.lastTimestamp, 1e-6)

        // ── Predict ──────────────────────────────────────────────────────────
        // F = [[1,0,dt,0],[0,1,0,dt],[0,0,1,0],[0,0,0,1]]
        let (px0, pz0, vx0, vz0) = state.x
        let px_pred = px0 + vx0 * dt
        let pz_pred = pz0 + vz0 * dt
        let vx_pred = vx0
        let vz_pred = vz0

        // Q — CWNA process noise (continuous-time discrete approximation)
        let dt2 = dt * dt
        let dt3 = dt2 * dt
        let dt4 = dt3 * dt
        let qa = sigmaAccel * sigmaAccel
        // Q = qa * [[dt4/4,0,dt3/2,0],[0,dt4/4,0,dt3/2],[dt3/2,0,dt2,0],[0,dt3/2,0,dt2]]
        let Q: [Double] = [
            qa * dt4 / 4, 0,            qa * dt3 / 2, 0,
            0,            qa * dt4 / 4, 0,            qa * dt3 / 2,
            qa * dt3 / 2, 0,            qa * dt2,     0,
            0,            qa * dt3 / 2, 0,            qa * dt2,
        ]

        // P_pred = F * P * F^T + Q
        let P = state.P
        // F*P (apply row of F to P):
        //  row 0: [P[0]+dt*P[8], P[1]+dt*P[9], P[2]+dt*P[10], P[3]+dt*P[11]]
        //  row 1: [P[4]+dt*P[12],P[5]+dt*P[13],P[6]+dt*P[14], P[7]+dt*P[15]]
        //  row 2: P[8..11]
        //  row 3: P[12..15]
        var FP = [Double](repeating: 0, count: 16)
        FP[0]  = P[0]  + dt * P[8];  FP[1]  = P[1]  + dt * P[9]
        FP[2]  = P[2]  + dt * P[10]; FP[3]  = P[3]  + dt * P[11]
        FP[4]  = P[4]  + dt * P[12]; FP[5]  = P[5]  + dt * P[13]
        FP[6]  = P[6]  + dt * P[14]; FP[7]  = P[7]  + dt * P[15]
        FP[8]  = P[8];               FP[9]  = P[9]
        FP[10] = P[10];              FP[11] = P[11]
        FP[12] = P[12];              FP[13] = P[13]
        FP[14] = P[14];              FP[15] = P[15]

        // (F*P)*F^T: F^T col j = F row j, so multiply FP row i by F^T col j
        // which is: FP[i,j] + FP[i,2]*dt (for j=0 from F^T col 0 having dt in row 2)
        // Systematically: P_pred[i,j] = sum_k FP[i,k]*F[j,k]
        //  F[0,:] = [1,0,dt,0]
        //  F[1,:] = [0,1,0,dt]
        //  F[2,:] = [0,0,1,0]
        //  F[3,:] = [0,0,0,1]
        var Pp = [Double](repeating: 0, count: 16)
        for i in 0..<4 {
            // col j = 0: dot(FP[i,:], F[0,:]) = FP[i,0] + dt*FP[i,2]
            Pp[i*4+0] = FP[i*4+0] + dt * FP[i*4+2]
            // col j = 1: FP[i,1] + dt*FP[i,3]
            Pp[i*4+1] = FP[i*4+1] + dt * FP[i*4+3]
            // col j = 2: FP[i,2]
            Pp[i*4+2] = FP[i*4+2]
            // col j = 3: FP[i,3]
            Pp[i*4+3] = FP[i*4+3]
        }
        // Add Q
        for i in 0..<16 { Pp[i] += Q[i] }

        // ── Update ───────────────────────────────────────────────────────────
        // H = [[1,0,0,0],[0,1,0,0]] (observe px, pz only)
        // S = H*Pp*H^T + R = top-left 2×2 of Pp + R
        let R = sigmaPosition * sigmaPosition
        let S00 = Pp[0]  + R
        let S01 = Pp[1]
        let S10 = Pp[4]
        let S11 = Pp[5] + R

        // S^-1 (2×2 inverse)
        let detS = S00 * S11 - S01 * S10
        guard abs(detS) > 1e-12 else {
            // Degenerate — return predicted state as-is
            var ns = state
            ns.x = (px_pred, pz_pred, vx_pred, vz_pred)
            ns.P = Pp
            ns.lastTimestamp = timestamp
            states[id] = ns
            return VelocityKalmanEstimate(px: px_pred, pz: pz_pred, vx: vx_pred, vz: vz_pred)
        }
        let Si00 =  S11 / detS
        let Si01 = -S01 / detS
        let Si10 = -S10 / detS
        let Si11 =  S00 / detS

        // K = Pp * H^T * S^-1
        // Pp * H^T = first two columns of Pp (4×2)
        // K (4×2)
        var K = [Double](repeating: 0, count: 8)
        for r in 0..<4 {
            let ph0 = Pp[r*4+0]  // (Pp*H^T)[r,0]
            let ph1 = Pp[r*4+1]  // (Pp*H^T)[r,1]
            K[r*2+0] = ph0 * Si00 + ph1 * Si10
            K[r*2+1] = ph0 * Si01 + ph1 * Si11
        }

        // Innovation y = z - H*x_pred = [mPX - px_pred, mPZ - pz_pred]
        let y0 = measuredPX - px_pred
        let y1 = measuredPZ - pz_pred

        // x_upd = x_pred + K * y
        let px_upd = px_pred + K[0] * y0 + K[1] * y1
        let pz_upd = pz_pred + K[2] * y0 + K[3] * y1
        let vx_upd = vx_pred + K[4] * y0 + K[5] * y1
        let vz_upd = vz_pred + K[6] * y0 + K[7] * y1

        // P_upd = (I - K*H) * Pp
        // (I - K*H)[r,c] where H selects first two rows:
        //   P_upd[r,c] = Pp[r,c] - K[r,0]*Pp[0,c] - K[r,1]*Pp[1,c]
        var Pupd = [Double](repeating: 0, count: 16)
        for r in 0..<4 {
            let k0 = K[r*2+0]
            let k1 = K[r*2+1]
            for c in 0..<4 {
                // row r of (I-KH): e_r - k0 * H_row0 - k1 * H_row1
                // = e_r - k0 * e_0 - k1 * e_1
                // dot with col c of Pp = Pp[r,c] - k0*Pp[0,c] - k1*Pp[1,c]
                Pupd[r*4+c] = Pp[r*4+c] - k0 * Pp[0*4+c] - k1 * Pp[1*4+c]
            }
        }

        let newState = KalmanState(
            x: (px_upd, pz_upd, vx_upd, vz_upd),
            P: Pupd,
            lastTimestamp: timestamp
        )
        states[id] = newState
        return VelocityKalmanEstimate(px: px_upd, pz: pz_upd, vx: vx_upd, vz: vz_upd)
    }
}
