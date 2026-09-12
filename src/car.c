#include "car.h"

const car_stats_t car_presets[CAR_COUNT] = {
    /* name              strength  speed  turning */
    { "Red Racer",       0.85f,    0.90f, 0.25f },  /* fast and far, hard to curve   */
    { "Blue Bulldozer",  0.65f,    0.35f, 0.45f },  /* short and heavy, rolls true   */
    { "Yellow Spinner",  0.55f,    0.55f, 0.95f },  /* weaker, but curves like crazy */
};
