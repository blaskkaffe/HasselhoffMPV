#include "render.h"
#include "hud.h"

#include <GL/gl.h>
#include <GL/glu.h>
#include <GL/glkos.h>
#include <math.h>

#define PI_F 3.14159265358979323846f

#define SCREEN_W 640.0f
#define SCREEN_H 480.0f

#define CAM_DIST      8.0f
#define CAM_HEIGHT    4.5f
#define CAM_LOOKAHEAD 3.0f

#define WALL_HEIGHT   1.2f
#define GROUND_CELL   5.0f

void render_init(void) {
    glKosInit();

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glClearDepth(1.0f);
    glClearColor(0.53f, 0.81f, 0.92f, 1.0f);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    gluPerspective(60.0f, SCREEN_W / SCREEN_H, 0.1f, 200.0f);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
}

static void quad_xz(float x0, float z0, float x1, float z1, float y) {
    glBegin(GL_QUADS);
    glVertex3f(x0, y, z0);
    glVertex3f(x1, y, z0);
    glVertex3f(x1, y, z1);
    glVertex3f(x0, y, z1);
    glEnd();
}

static void draw_ground(const course_t *course) {
    int cols = (int)((course->half_width * 2.0f) / GROUND_CELL);
    int rows = (int)(course->length / GROUND_CELL);

    for(int rz = 0; rz < rows; rz++) {
        for(int cx = 0; cx < cols; cx++) {
            float x0 = -course->half_width + (float)cx * GROUND_CELL;
            float z0 = (float)rz * GROUND_CELL;

            if((rz + cx) & 1)
                glColor3f(0.20f, 0.55f, 0.20f);
            else
                glColor3f(0.26f, 0.65f, 0.26f);

            quad_xz(x0, z0, x0 + GROUND_CELL, z0 + GROUND_CELL, 0.0f);
        }
    }
}

static void draw_walls(const course_t *course) {
    glColor3f(0.55f, 0.35f, 0.15f);

    for(int i = 0; i < course->wall_count; i++) {
        const wall_t *w = &course->walls[i];

        glBegin(GL_QUADS);
        glVertex3f(w->ax, 0.0f, w->az);
        glVertex3f(w->bx, 0.0f, w->bz);
        glVertex3f(w->bx, WALL_HEIGHT, w->bz);
        glVertex3f(w->ax, WALL_HEIGHT, w->az);
        glEnd();
    }
}

static void draw_hole(const course_t *course) {
    const int segments = 16;
    float r = course->hole_radius;

    glColor3f(0.05f, 0.05f, 0.05f);
    glBegin(GL_TRIANGLE_FAN);
    glVertex3f(course->hole_x, 0.02f, course->hole_z);
    for(int i = 0; i <= segments; i++) {
        float a = (float)i / (float)segments * 2.0f * PI_F;
        glVertex3f(course->hole_x + sinf(a) * r, 0.02f, course->hole_z + cosf(a) * r);
    }
    glEnd();

    /* Flagstick + flag. */
    glColor3f(0.9f, 0.9f, 0.9f);
    glBegin(GL_LINES);
    glVertex3f(course->hole_x, 0.0f, course->hole_z);
    glVertex3f(course->hole_x, 3.0f, course->hole_z);
    glEnd();

    glColor3f(0.85f, 0.1f, 0.1f);
    glBegin(GL_TRIANGLES);
    glVertex3f(course->hole_x, 3.0f, course->hole_z);
    glVertex3f(course->hole_x, 2.6f, course->hole_z);
    glVertex3f(course->hole_x + 0.6f, 2.8f, course->hole_z);
    glEnd();
}

static void draw_box(float hx, float hy, float hz,
                      float r, float g, float b) {
    /* Cheap fake shading: brighter top, darker bottom, since we run with
       no lighting at all (keeps this module free of normals/materials). */
    glColor3f(r * 1.25f, g * 1.25f, b * 1.25f);
    glBegin(GL_QUADS);
    glVertex3f(-hx, hy,  hz);
    glVertex3f( hx, hy,  hz);
    glVertex3f( hx, hy, -hz);
    glVertex3f(-hx, hy, -hz);
    glEnd();

    glColor3f(r, g, b);
    glBegin(GL_QUADS);
    glVertex3f(-hx, -hy, hz);
    glVertex3f( hx, -hy, hz);
    glVertex3f( hx,  hy, hz);
    glVertex3f(-hx,  hy, hz);
    glEnd();
    glBegin(GL_QUADS);
    glVertex3f( hx, -hy, -hz);
    glVertex3f(-hx, -hy, -hz);
    glVertex3f(-hx,  hy, -hz);
    glVertex3f( hx,  hy, -hz);
    glEnd();
    glBegin(GL_QUADS);
    glVertex3f(hx, -hy,  hz);
    glVertex3f(hx, -hy, -hz);
    glVertex3f(hx,  hy, -hz);
    glVertex3f(hx,  hy,  hz);
    glEnd();
    glBegin(GL_QUADS);
    glVertex3f(-hx, -hy, -hz);
    glVertex3f(-hx, -hy,  hz);
    glVertex3f(-hx,  hy,  hz);
    glVertex3f(-hx,  hy, -hz);
    glEnd();

    glColor3f(r * 0.6f, g * 0.6f, b * 0.6f);
    glBegin(GL_QUADS);
    glVertex3f(-hx, -hy, -hz);
    glVertex3f( hx, -hy, -hz);
    glVertex3f( hx, -hy,  hz);
    glVertex3f(-hx, -hy,  hz);
    glEnd();
}

static void draw_car(const car_body_t *car) {
    const float body_hx = 0.4f, body_hy = 0.18f, body_hz = 0.65f;
    const float cab_hx = 0.3f, cab_hy = 0.12f, cab_hz = 0.32f;
    const float wheel_hx = 0.08f, wheel_hy = 0.14f, wheel_hz = 0.14f;

    glPushMatrix();
    glTranslatef(car->x, body_hy + wheel_hy, car->z);
    glRotatef(car->heading * 180.0f / PI_F, 0.0f, 1.0f, 0.0f);

    draw_box(body_hx, body_hy, body_hz, 0.75f, 0.08f, 0.08f);

    glPushMatrix();
    glTranslatef(0.0f, body_hy + cab_hy, 0.05f);
    draw_box(cab_hx, cab_hy, cab_hz, 0.85f, 0.85f, 0.9f);
    glPopMatrix();

    static const float wheel_x[4] = { 1.0f, -1.0f, 1.0f, -1.0f };
    static const float wheel_z[4] = { 1.0f, 1.0f, -1.0f, -1.0f };

    for(int i = 0; i < 4; i++) {
        glPushMatrix();
        glTranslatef(wheel_x[i] * (body_hx + 0.03f), -wheel_hy + 0.02f,
                     wheel_z[i] * (body_hz - 0.15f));
        draw_box(wheel_hx, wheel_hy, wheel_hz, 0.05f, 0.05f, 0.05f);
        glPopMatrix();
    }

    glPopMatrix();
}

static void draw_aim_arrow(const car_body_t *car) {
    float fwdx = sinf(car->heading), fwdz = cosf(car->heading);
    float sidex = cosf(car->heading), sidez = -sinf(car->heading);
    float tip_x = car->x + fwdx * 4.0f, tip_z = car->z + fwdz * 4.0f;
    float base_x = car->x + fwdx * 0.8f, base_z = car->z + fwdz * 0.8f;
    float head_back_x = tip_x - fwdx * 0.6f, head_back_z = tip_z - fwdz * 0.6f;

    glColor3f(1.0f, 1.0f, 0.2f);
    glBegin(GL_LINES);
    glVertex3f(base_x, 0.05f, base_z);
    glVertex3f(head_back_x, 0.05f, head_back_z);
    glEnd();

    glBegin(GL_TRIANGLES);
    glVertex3f(tip_x, 0.05f, tip_z);
    glVertex3f(head_back_x + sidex * 0.3f, 0.05f, head_back_z + sidez * 0.3f);
    glVertex3f(head_back_x - sidex * 0.3f, 0.05f, head_back_z - sidez * 0.3f);
    glEnd();
}

static void draw_sunk_banner(void) {
    float cx = SCREEN_W * 0.5f, cy = SCREEN_H * 0.75f;
    float r = 40.0f;

    glColor3f(0.1f, 0.8f, 0.2f);
    glBegin(GL_TRIANGLE_FAN);
    glVertex2f(cx, cy);
    for(int i = 0; i <= 24; i++) {
        float a = (float)i / 24.0f * 2.0f * PI_F;
        glVertex2f(cx + sinf(a) * r, cy + cosf(a) * r);
    }
    glEnd();
}

void render_frame(const car_body_t *car, const course_t *course, const hud_info_t *hud) {
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    float fwdx = sinf(car->heading), fwdz = cosf(car->heading);
    float eye_x = car->x - fwdx * CAM_DIST;
    float eye_z = car->z - fwdz * CAM_DIST;
    float ctr_x = car->x + fwdx * CAM_LOOKAHEAD;
    float ctr_z = car->z + fwdz * CAM_LOOKAHEAD;

    gluLookAt(eye_x, CAM_HEIGHT, eye_z, ctr_x, 0.5, ctr_z, 0.0, 1.0, 0.0);

    draw_ground(course);
    draw_walls(course);
    draw_hole(course);
    if(hud->show_aim_arrow)
        draw_aim_arrow(car);
    draw_car(car);

    hud_begin_overlay();
    if(hud->show_power_meter)
        hud_draw_power_meter(hud->charge01, hud->curve01);
    if(hud->show_sunk_banner)
        draw_sunk_banner();
    hud_draw_number(20.0f, 440.0f, 18.0f, 28.0f, hud->strokes);
    hud_draw_number(20.0f, 395.0f, 12.0f, 18.0f, hud->par);
    hud_end_overlay();

    glKosSwapBuffers();
}
