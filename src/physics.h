/* Wind-Up Fairway
   src/physics.h

   Pure C car-on-a-flat-plane physics: launch, rolling friction, curve
   ("spin") decay, wall bouncing, and hole capture. Deliberately has no
   KOS/GL dependency so it can be reasoned about (and unit tested on a PC)
   independently of the Dreamcast-specific rendering/input code. */

#ifndef PHYSICS_H
#define PHYSICS_H

#include "car.h"
#include "course.h"

typedef struct {
    float x, z;           /* position on the ground plane */
    float heading;        /* radians; facing direction, used for rendering */
    float vx, vz;          /* velocity, units/sec */
    float spin;            /* current curve rate, radians/sec, decays with speed */
    float launch_speed;    /* speed immediately after launch; used to fade spin */
    int   moving;          /* 1 while rolling */
} car_body_t;

typedef enum {
    PHYS_EVENT_NONE = 0,
    PHYS_EVENT_STOPPED,
    PHYS_EVENT_SUNK,
} phys_event_t;

/* Radius of the car for collision purposes, in game units. */
#define CAR_RADIUS 0.6f

void physics_reset(car_body_t *car, const course_t *course);

/* Launches the car from its current position.
   aim_angle   - radians, direction to fire in
   charge01    - 0..1, how far the shot was charged
   curve01     - -1..1, curve bias locked in at the start of the charge
   stats       - the active car's stat block */
void physics_launch(car_body_t *car, float aim_angle, float charge01,
                     float curve01, const car_stats_t *stats);

/* Advances the simulation by dt seconds. Returns the event (if any) that
   occurred this tick. */
phys_event_t physics_update(car_body_t *car, const car_stats_t *stats,
                             const course_t *course, float dt);

#endif /* PHYSICS_H */
