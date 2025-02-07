use crate::{config::Config, map};
use rand::seq::SliceRandom;
use rand::Rng;
use rustler::NifMap;
use serde::Deserialize;

use crate::{effect::Effect, map::Position};

#[derive(Deserialize)]
pub struct ProjectileConfigFile {
    name: String,
    base_damage: u64,
    base_speed: u64,
    base_size: u64,
    on_hit_effects: Vec<String>,
    duration_ms: u64,
    max_distance: u64,
    remove_on_collision: bool,
    bounce: bool,
}

#[derive(NifMap, Clone)]
pub struct ProjectileConfig {
    pub name: String,
    base_damage: u64,
    base_speed: u64,
    base_size: u64,
    on_hit_effects: Vec<Effect>,
    duration_ms: u64,
    max_distance: u64,
    remove_on_collision: bool,
    bounce: bool,
}

#[derive(NifMap, Clone)]
pub struct Projectile {
    pub name: String,
    pub damage: u64,
    pub speed: u64,
    pub size: u64,
    pub on_hit_effects: Vec<Effect>,
    pub duration_ms: u64,
    pub max_distance: u64,
    pub id: u64,
    pub position: Position,
    pub direction_angle: f32,
    pub player_id: u64,
    pub active: bool, // TODO: this should be `status` field with an enum value
    pub remove_on_collision: bool,
    pub attacked_player_ids: Vec<u64>,
    pub bounce: bool,
}

impl ProjectileConfig {
    pub(crate) fn from_config_file(
        projectiles: Vec<ProjectileConfigFile>,
        effects: &[Effect],
    ) -> Vec<ProjectileConfig> {
        projectiles
            .into_iter()
            .map(|config| {
                let effects = effects
                    .iter()
                    .filter(|effect| config.on_hit_effects.contains(&effect.name))
                    .cloned()
                    .collect();

                ProjectileConfig {
                    name: config.name,
                    base_damage: config.base_damage,
                    base_speed: config.base_speed,
                    base_size: config.base_size,
                    on_hit_effects: effects,
                    duration_ms: config.duration_ms,
                    max_distance: config.max_distance,
                    remove_on_collision: config.remove_on_collision,
                    bounce: config.bounce,
                }
            })
            .collect()
    }
}

impl Projectile {
    pub fn new(
        id: u64,
        position: Position,
        direction_angle: f32,
        player_id: u64,
        config: &ProjectileConfig,
    ) -> Self {
        Projectile {
            name: config.name.clone(),
            damage: config.base_damage,
            speed: config.base_speed,
            size: config.base_speed,
            on_hit_effects: config.on_hit_effects.clone(),
            duration_ms: config.duration_ms,
            max_distance: config.max_distance,
            remove_on_collision: config.remove_on_collision,
            id,
            position,
            direction_angle,
            player_id,
            active: true,
            attacked_player_ids: vec![],
            bounce: config.bounce,
        }
    }

    pub fn calculate_bounce(&mut self, position: &Position) {
        let player_projectile_angle = map::angle_between_positions(&self.position, position);

        let angle_between_projectile_player =
            (player_projectile_angle + 180.) - self.direction_angle;

        if angle_between_projectile_player > 0. {
            self.direction_angle =
                (player_projectile_angle + angle_between_projectile_player) % 360.;
        } else {
            self.direction_angle =
                (player_projectile_angle - angle_between_projectile_player) % 360.;
        }
    }

    pub fn update_attacked_list(&mut self, id: &u64) {
        if !self.attacked_player_ids.contains(id) {
            self.attacked_player_ids = vec![id.clone()];
        }
    }
}

pub fn spawn_ball(config: &Config, id: u64) -> Option<Projectile> {
    let rng = &mut rand::thread_rng();
    let angle = rng.gen_range(0.0..360.);
    Some(Projectile::new(
        id,
        Position {
            x: rng.gen_range(0..50),
            y: rng.gen_range(0..50),
        },
        angle,
        15,
        &config.projectiles[0],
    ))
}
