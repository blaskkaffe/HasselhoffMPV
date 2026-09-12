/* Wind-Up Fairway
   src/car.h

   Toy car definitions. Each car is described by three player-facing stats
   (strength, speed, turning) instead of a golf club/ball. physics.c turns
   these 0..1 stats into concrete launch speed, rolling friction, and curve
   response. */

#ifndef CAR_H
#define CAR_H

typedef struct {
    const char *name;
    float strength;  /* 0..1: how far a full pull-back charge launches the car */
    float speed;     /* 0..1: higher = less rolling friction, coasts farther */
    float turning;   /* 0..1: higher = sharper curve response to steering input */
} car_stats_t;

#define CAR_COUNT 3

/* Preset toy cars. Add more here as content grows. */
extern const car_stats_t car_presets[CAR_COUNT];

#endif /* CAR_H */
