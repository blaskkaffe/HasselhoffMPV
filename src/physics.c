#include "physics.h"
#include <math.h>

#define PI_F 3.14159265358979323846f

#define BASE_LAUNCH_SPEED    9.0f              /* units/sec, full strength+charge */
#define BASE_FRICTION        3.0f              /* units/sec^2 deceleration */
#define MAX_SPIN_RATE        (PI_F * 1.5f)     /* rad/sec, full turning+curve */
#define CAPTURE_MAX_SPEED    6.0f              /* must be under this to sink */
#define STOP_SPEED_EPS       0.05f
#define WALL_RESTITUTION     0.55f

/* Direction convention shared with render.c: heading 0 faces +Z, and
   increasing heading rotates toward +X, i.e. forward = (sin(h), cos(h)).
   Keep any future direction math consistent with this. */

static void closest_point_on_segment(float px, float pz,
                                      float ax, float az,
                                      float bx, float bz,
                                      float *outx, float *outz) {
    float abx = bx - ax, abz = bz - az;
    float len2 = abx * abx + abz * abz;
    float t = 0.0f;

    if(len2 > 1e-6f)
        t = ((px - ax) * abx + (pz - az) * abz) / len2;

    if(t < 0.0f) t = 0.0f;
    if(t > 1.0f) t = 1.0f;

    *outx = ax + abx * t;
    *outz = az + abz * t;
}

void physics_reset(car_body_t *car, const course_t *course) {
    car->x = course->start_x;
    car->z = course->start_z;
    car->heading = course->start_heading;
    car->vx = 0.0f;
    car->vz = 0.0f;
    car->spin = 0.0f;
    car->launch_speed = 0.0f;
    car->moving = 0;
}

void physics_launch(car_body_t *car, float aim_angle, float charge01,
                     float curve01, const car_stats_t *stats) {
    float speed = BASE_LAUNCH_SPEED * (0.6f + 0.8f * stats->strength) * charge01;

    car->heading = aim_angle;
    car->vx = sinf(aim_angle) * speed;
    car->vz = cosf(aim_angle) * speed;
    car->spin = MAX_SPIN_RATE * stats->turning * curve01;
    car->launch_speed = speed;
    car->moving = (speed > 0.0f) ? 1 : 0;
}

phys_event_t physics_update(car_body_t *car, const car_stats_t *stats,
                             const course_t *course, float dt) {
    if(!car->moving)
        return PHYS_EVENT_NONE;

    float speed = sqrtf(car->vx * car->vx + car->vz * car->vz);

    /* Curve: rotate the velocity vector, fading out as speed bleeds off so
       the car's "wound up" steering relaxes the same way a real pull-back
       toy's front wheels do. */
    if(car->launch_speed > 0.0001f) {
        float ratio = speed / car->launch_speed;
        float turn = car->spin * ratio * dt;
        float ca = cosf(turn), sa = sinf(turn);
        float nvx = car->vx * ca + car->vz * sa;
        float nvz = car->vz * ca - car->vx * sa;
        car->vx = nvx;
        car->vz = nvz;
    }

    /* Rolling friction. */
    float friction = BASE_FRICTION * (1.3f - 0.9f * stats->speed);
    float new_speed = speed - friction * dt;
    if(new_speed < 0.0f) new_speed = 0.0f;

    if(speed > 0.0001f) {
        float scale = new_speed / speed;
        car->vx *= scale;
        car->vz *= scale;
    }
    speed = new_speed;

    if(speed > 0.01f)
        car->heading = atan2f(car->vx, car->vz);

    float newx = car->x + car->vx * dt;
    float newz = car->z + car->vz * dt;

    /* Bounce off any wall the car would now be overlapping. */
    for(int i = 0; i < course->wall_count; i++) {
        const wall_t *w = &course->walls[i];
        float cx, cz;
        closest_point_on_segment(newx, newz, w->ax, w->az, w->bx, w->bz, &cx, &cz);

        float dx = newx - cx, dz = newz - cz;
        float dist = sqrtf(dx * dx + dz * dz);

        if(dist < CAR_RADIUS) {
            float nx, nz;
            if(dist > 0.0001f) {
                nx = dx / dist;
                nz = dz / dist;
            } else {
                /* Degenerate: car center sits exactly on the wall line.
                   Push out along the wall's perpendicular. */
                float abx = w->bx - w->ax, abz = w->bz - w->az;
                float ablen = sqrtf(abx * abx + abz * abz) + 1e-6f;
                nx = -abz / ablen;
                nz = abx / ablen;
            }

            float penetration = CAR_RADIUS - dist;
            newx += nx * penetration;
            newz += nz * penetration;

            float dot = car->vx * nx + car->vz * nz;
            if(dot < 0.0f) {
                car->vx -= (1.0f + WALL_RESTITUTION) * dot * nx;
                car->vz -= (1.0f + WALL_RESTITUTION) * dot * nz;
            }
        }
    }

    car->x = newx;
    car->z = newz;

    float hdx = car->x - course->hole_x;
    float hdz = car->z - course->hole_z;
    float dist_to_hole = sqrtf(hdx * hdx + hdz * hdz);

    if(dist_to_hole < course->hole_radius && speed < CAPTURE_MAX_SPEED) {
        car->vx = 0.0f;
        car->vz = 0.0f;
        car->moving = 0;
        return PHYS_EVENT_SUNK;
    }

    if(speed < STOP_SPEED_EPS) {
        car->vx = 0.0f;
        car->vz = 0.0f;
        car->moving = 0;
        return PHYS_EVENT_STOPPED;
    }

    return PHYS_EVENT_NONE;
}
