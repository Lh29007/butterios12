#pragma once

#include <stddef.h>

enum { A_UP, A_DOWN, A_LEFT, A_RIGHT, A_Z, A_X, A_C, A_ENTER, A_SHIFT, A_ESC, A_COUNT };

typedef struct { const char *key; const char *label; int defVK; } BSAction;

static const BSAction kActions[A_COUNT] = {
    {"up", "Haut", 0x26},      {"down", "Bas", 0x28},       {"left", "Gauche", 0x25},
    {"right", "Droite", 0x27}, {"z", "Z", 0x5A},            {"x", "X", 0x58},
    {"c", "C", 0x43},          {"enter", "Entree", 0x0D},   {"shift", "Shift", 0x10},
    {"esc", "Echap", 0x1B},
};

typedef struct { const char *name; int vk; } BSKeyChoice;

static const BSKeyChoice kKeyChoices[] = {
    {"Z", 0x5A}, {"X", 0x58}, {"C", 0x43}, {"V", 0x56}, {"A", 0x41}, {"S", 0x53},
    {"D", 0x44}, {"W", 0x57}, {"Q", 0x51}, {"E", 0x45}, {"F", 0x46}, {"R", 0x52},
    {"Espace", 0x20}, {"Entree", 0x0D}, {"Shift", 0x10}, {"Ctrl", 0x11},
    {"Echap", 0x1B}, {"Tab", 0x09}, {"Haut", 0x26}, {"Bas", 0x28},
    {"Gauche", 0x25}, {"Droite", 0x27},
};
#define N_KEY_CHOICES (sizeof(kKeyChoices) / sizeof(kKeyChoices[0]))

int BSMappedVK(int action);

static inline const char *BSKeyName(int vk) {
    for (size_t i = 0; i < N_KEY_CHOICES; i++) {
        if (kKeyChoices[i].vk == vk) return kKeyChoices[i].name;
    }
    return "?";
}
