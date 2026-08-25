// Turning a live entity into an EntityPose: the interpolated position, the
// head/limb angles and every mob-specific flag the animator reads. Lifted
// verbatim from the Metal drawEntities so both clients pose identically
// (PORTING module 07 animation slice).

import Foundation

/// the pose for one entity this frame. `partial` is the tick interpolation.
public func pebEntityPose(_ w: World, _ ent: Entity, partial: Double) -> EntityPose {
    let liv = ent as? LivingEntity
    let ix = ent.prevX + (ent.x - ent.prevX) * partial
    let iy = ent.prevY + (ent.y - ent.prevY) * partial
    let iz = ent.prevZ + (ent.z - ent.prevZ) * partial
    let yaw = ent.prevYaw + wrapAngle(ent.yaw - ent.prevYaw) * partial
    let bx = ifloor(ent.x), by = ifloor(ent.y + ent.height * 0.5), bz = ifloor(ent.z)
    let deathFlip = (liv?.deathTime ?? 0) > 0 ? min(1.0, Double(liv!.deathTime) / 20) : 0
    var pose = EntityPose()
    pose.x = ix; pose.y = iy; pose.z = iz
    pose.yaw = yaw
    pose.headYaw = liv != nil ? wrapAngle(liv!.headYaw - yaw) : 0
    pose.pitch = ent.pitch
    pose.limbSwing = liv?.limbSwing ?? 0
    pose.limbAmp = liv?.limbAmp ?? 0
    pose.attackSwing = liv?.attackAnim ?? 0
    pose.hurtFlash = (liv?.hurtTime ?? 0) > 0 ? Double(liv!.hurtTime) / 10 : deathFlip * 0.6
    pose.scale = 1
    pose.baby = ent.data.baby ?? false
    pose.sky = w.getSkyLight(bx, by, bz)
    pose.block = w.getBlockLight(bx, by, bz)
    pose.ageTicks = ent.age
    pose.airborne = !ent.onGround
    pose.aiming = (ent as? Mob)?.target != nil
    pose.crossed = pose.aiming
    pose.grazing = ent.data.grazing ?? false
    pose.sitting = (ent as? Mob)?.sitting ?? false
    pose.open = (ent as? Shulker)?.peekAmount ?? 0
    pose.hanging = ent.type == "bat" && ent.onGround
    pose.alpha = deathFlip > 0 ? 1 - deathFlip * 0.6 : 1
    if let pl = ent as? Player, pl.isBlocking() {
        pose.blockingHand = pl.useItemHand
    }
    return pose
}

/// the 24 part matrices for a live entity in one call
public func pebEntityParts(_ w: World, _ ent: Entity, model: MobModel,
                           partial: Double, time: Double) -> [Mat4f] {
    pebPoseParts(model, pebEntityPose(w, ent, partial: partial), time)
}

/// flatten part matrices into the 384-float stream pb_vk_push_entity takes
public func pebFlattenParts(_ mats: [Mat4f]) -> [Float] {
    var out = [Float](repeating: 0, count: 24 * 16)
    for i in 0..<min(24, mats.count) {
        for k in 0..<16 { out[i * 16 + k] = mats[i].m[k] }
    }
    return out
}
