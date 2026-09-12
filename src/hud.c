#include "hud.h"

#include <GL/gl.h>
#include <GL/glu.h>

#define SCREEN_W 640.0f
#define SCREEN_H 480.0f

void hud_begin_overlay(void) {
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0.0, SCREEN_W, 0.0, SCREEN_H, -1.0, 1.0);

    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glDisable(GL_DEPTH_TEST);
}

void hud_end_overlay(void) {
    glEnable(GL_DEPTH_TEST);

    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(GL_MODELVIEW);
    glPopMatrix();
}

static void filled_quad(float x0, float y0, float x1, float y1) {
    glBegin(GL_QUADS);
    glVertex2f(x0, y0);
    glVertex2f(x1, y0);
    glVertex2f(x1, y1);
    glVertex2f(x0, y1);
    glEnd();
}

void hud_draw_power_meter(float charge01, float curve01) {
    const float x0 = 220.0f, x1 = 420.0f;
    const float y0 = 20.0f, y1 = 44.0f;
    const float w = x1 - x0;

    if(charge01 < 0.0f) charge01 = 0.0f;
    if(charge01 > 1.0f) charge01 = 1.0f;

    /* Outline (drawn slightly oversized so it frames the fill). */
    glColor3f(1.0f, 1.0f, 1.0f);
    glBegin(GL_LINE_LOOP);
    glVertex2f(x0 - 2.0f, y0 - 2.0f);
    glVertex2f(x1 + 2.0f, y0 - 2.0f);
    glVertex2f(x1 + 2.0f, y1 + 2.0f);
    glVertex2f(x0 - 2.0f, y1 + 2.0f);
    glEnd();

    /* Fill, green -> red as the charge grows. */
    glColor3f(charge01, 1.0f - charge01, 0.0f);
    filled_quad(x0, y0, x0 + w * charge01, y1);

    /* Curve marker: a vertical tick offset from center by the locked-in
       curve bias, drawn across the whole bar height. */
    float center_x = x0 + w * 0.5f;
    float marker_x = center_x + (w * 0.5f) * curve01;
    glColor3f(0.1f, 0.1f, 1.0f);
    filled_quad(marker_x - 2.0f, y0 - 6.0f, marker_x + 2.0f, y1 + 6.0f);
}

/* 7-segment layout, bit order: a b c d e f g (a = top bar). */
static const unsigned char digit_segments[10] = {
    0x7E, /* 0: a b c d e f   */
    0x30, /* 1: b c           */
    0x6D, /* 2: a b d e g     */
    0x79, /* 3: a b c d g     */
    0x33, /* 4: b c f g       */
    0x5B, /* 5: a c d f g     */
    0x5F, /* 6: a c d e f g   */
    0x70, /* 7: a b c         */
    0x7F, /* 8: a b c d e f g */
    0x7B, /* 9: a b c d f g   */
};

#define SEG_A 0x40
#define SEG_B 0x20
#define SEG_C 0x10
#define SEG_D 0x08
#define SEG_E 0x04
#define SEG_F 0x02
#define SEG_G 0x01

static void hseg(float x0, float x1, float y_center, float thick) {
    filled_quad(x0, y_center - thick * 0.5f, x1, y_center + thick * 0.5f);
}

static void vseg(float y0, float y1, float x_center, float thick) {
    filled_quad(x_center - thick * 0.5f, y0, x_center + thick * 0.5f, y1);
}

static void draw_digit(float x, float y, float w, float h, int digit) {
    if(digit < 0 || digit > 9) digit = 0;
    unsigned char seg = digit_segments[digit];
    float th = w * 0.22f;
    float mid_y = y + h * 0.5f;

    glColor3f(1.0f, 0.85f, 0.1f);

    if(seg & SEG_A) hseg(x + th, x + w - th, y + h - th * 0.5f, th);
    if(seg & SEG_G) hseg(x + th, x + w - th, mid_y, th);
    if(seg & SEG_D) hseg(x + th, x + w - th, y + th * 0.5f, th);

    if(seg & SEG_F) vseg(mid_y, y + h - th, x + th * 0.5f, th);
    if(seg & SEG_B) vseg(mid_y, y + h - th, x + w - th * 0.5f, th);
    if(seg & SEG_E) vseg(y + th, mid_y, x + th * 0.5f, th);
    if(seg & SEG_C) vseg(y + th, mid_y, x + w - th * 0.5f, th);
}

void hud_draw_number(float x, float y, float digit_w, float digit_h, int value) {
    char digits[12];
    int count = 0;

    if(value < 0) value = 0;

    do {
        digits[count++] = (char)(value % 10);
        value /= 10;
    } while(value > 0 && count < (int)sizeof(digits));

    float spacing = digit_w * 1.3f;
    float cursor = x + spacing * (float)(count - 1);

    for(int i = 0; i < count; i++) {
        draw_digit(cursor, y, digit_w, digit_h, digits[i]);
        cursor -= spacing;
    }
}
