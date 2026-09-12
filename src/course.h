/* Wind-Up Fairway
   src/course.h

   Flat-plane course description: a rectangle of "green" bounded by wall
   segments (reflective), a start point, and a hole. Units are game units;
   treat 1 unit as roughly 15cm so a course reads as a tabletop-scale track
   for pull-back toy cars. Coordinates use the XZ ground plane (Y is up). */

#ifndef COURSE_H
#define COURSE_H

typedef struct {
    float ax, az;
    float bx, bz;
} wall_t;

typedef struct {
    const char *name;
    int   par;

    float start_x, start_z;
    float start_heading;   /* radians, initial aim direction */

    float hole_x, hole_z;
    float hole_radius;

    float half_width;      /* fairway extends +/- half_width in X */
    float length;          /* fairway extends 0..length in Z */

    const wall_t *walls;
    int wall_count;
} course_t;

extern const course_t course_hole1;

#endif /* COURSE_H */
