defmodule DarkWorldsServer.RunnerSupervisor.BotPlayer do
  use GenServer, restart: :transient
  require Logger

  # The random factor will add a layer of randomness to bot actions
  # The following actions will be afected:
  # - Bot decision, the bot will start a wandering cicle with an fourth times
  #   chance and an eight times chance to do nothing
  # - Every attack the bot do will have a tilt that's decided with the random factor
  # - Add an additive to the range of attacks they're not always accurate
  # - Add some miliseconds to the time of decision of the bot
  @random_factor Enum.random([10, 20, 30])

  # This variable will decide how much time passes between bot decisions in milis
  @decide_delay_ms 500 + @random_factor * 2

  # We'll decide the view range of a bot measured in grid cells
  # e.g. from {x=1, y=1} to {x=5, y=1} you have 4 cells
  @visibility_max_range_cells 2000

  # This number determines the amount of players needed in proximity for the bot to flee
  @amount_of_players_to_flee 3

  # The numbers of cell close to the bot in wich the enemies will count to flee
  @range_of_players_to_flee @visibility_max_range_cells + 500

  # The number of minimum playable radius where the bot could flee
  @min_playable_radius_flee 5000

  # Number to substract to the playable radio
  @radius_sub_to_escape 500

  # This is the amount of time between bots messages
  @game_tick_rate_ms 30

  # This variable will determine an additive number to the chances of stoping chacing a player and
  # start wandering for the same time he has been chasing it
  # for example:
  #   -if you want the bots no never chace you can can change this value to 100
  #   -if you want the bots always chace you can can change this value to 0
  # keep in mind that the chace timer is also determined by the random factor value
  @chase_timer_adittive 5

  @prepare_for_battle_time_ms 10_000

  #######
  # API #
  #######
  def start_link(connection_pid, config) do
    GenServer.start_link(__MODULE__, {connection_pid, config})
  end

  def add_bot(bot_pid, bot_id) do
    GenServer.cast(bot_pid, {:add_bot, bot_id})
  end

  def toggle_bots(bot_pid, bots_active) do
    GenServer.cast(bot_pid, {:bots_enabled, bots_active})
  end

  #######################
  # GenServer callbacks #
  #######################
  @impl GenServer
  def init({connection_pid, config}) do
    {:ok,
     %{
       connection_pid: connection_pid,
       config: config,
       bots_enabled: true,
       game_tick_rate: @game_tick_rate_ms,
       players: [],
       bots: %{},
       game_state: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:add_bot, bot_id}, state) do
    # TODO remove this once we implement the server blocking the messages while the match loads
    Process.send_after(self(), {:decide_action, bot_id}, @prepare_for_battle_time_ms)
    Process.send_after(self(), {:do_action, bot_id}, @prepare_for_battle_time_ms)

    {:noreply,
     put_in(state, [:bots, bot_id], %{
       alive: true,
       objective: :nothing,
       current_wandering_position: nil,
       chase_timer: 0
     })}
  end

  def handle_cast({:bots_enabled, toggle}, state) do
    {:noreply, %{state | bots_enabled: toggle}}
  end

  @impl GenServer
  def handle_info({:decide_action, bot_id}, state) do
    bot_state = get_in(state, [:bots, bot_id])

    new_bot_state =
      case bot_state do
        %{action: :die} ->
          bot_state

        bot_state ->
          Process.send_after(self(), {:decide_action, bot_id}, @decide_delay_ms + @random_factor * 2)

          bot = Enum.find(state.players, fn player -> player.id == bot_id end)

          closest_entities = get_closest_entities(state.game_state, bot)

          bot_state
          |> decide_objective(state, bot_id, closest_entities)
          |> decide_action(bot_id, state.players, state, closest_entities)
      end

    state = put_in(state, [:bots, bot_id], new_bot_state)

    {:noreply, state}
  end

  def handle_info({:do_action, bot_id}, state) do
    bot_state = get_in(state, [:bots, bot_id])

    if bot_state.alive do
      Process.send_after(self(), {:do_action, bot_id}, state.game_tick_rate)
      do_action(state.connection_pid, state, bot_state, bot_id)
    end

    {:noreply, state}
  end

  def handle_info({:game_state, game_state}, state) do
    players =
      game_state.players
      |> Enum.map(&Map.take(&1, [:id, :health, :position]))
      |> Enum.sort_by(& &1.health, :desc)

    bots =
      Enum.reduce(players, state.bots, fn player, acc_bots ->
        case {player.health <= 0, acc_bots[player.id]} do
          {true, bot} when not is_nil(bot) -> put_in(acc_bots, [player.id, :alive], false)
          _ -> acc_bots
        end
      end)

    {:noreply, %{state | players: players, bots: bots, game_state: game_state}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  #############################
  # Callbacks implementations #
  #############################
  defp decide_action(%{alive: false} = bot_state, _, _, _game_state, _closest_entities) do
    Map.put(bot_state, :action, :die)
  end

  defp decide_action(
         %{objective: :wander} = bot_state,
         bot_id,
         players,
         _game_state,
         _closest_entities
       ) do
    bot = Enum.find(players, fn player -> player.id == bot_id end)

    set_correct_wander_state(bot, bot_state)
  end

  defp decide_action(
         %{objective: :chase_loot} = bot_state,
         _bot_id,
         _players,
         %{game_state: game_state},
         %{loots_by_distance: loots_by_distance}
       ) do
    closest_loot = List.first(loots_by_distance)

    angle = closest_loot.angle_direction_to_entity

    center = game_state.shrinking_center
    radius = game_state.playable_radius

    if position_out_of_radius?(closest_loot.entity_position, center, radius) do
      flee_angle_direction = if angle <= 0, do: angle + 180, else: angle - 180
      Map.put(bot_state, :action, {:move, flee_angle_direction})
    else
      Map.put(bot_state, :action, {:move, angle})
    end
  end

  defp decide_action(
         %{objective: :chase_enemy} = bot_state,
         bot_id,
         _players,
         %{game_state: game_state, config: config},
         %{enemies_by_distance: enemies_by_distance}
       ) do
    bot = Enum.find(game_state.players, fn player -> player.id == bot_id end)

    closest_enemy = List.first(enemies_by_distance)

    amount_of_players_in_flee_proximity =
      enemies_by_distance
      |> Enum.count(fn p -> p.distance_to_entity < @range_of_players_to_flee end)

    danger_zone =
      amount_of_players_in_flee_proximity >= @amount_of_players_to_flee or
        (bot.health <= 25 and amount_of_players_in_flee_proximity >= 1)

    playable_radius_closed = game_state.playable_radius <= @min_playable_radius_flee

    new_state =
      cond do
        random_chance(bot_state.chase_timer / 10) ->
          bot = Enum.find(game_state.players, fn player -> player.id == bot_id end)

          put_wandering_position(bot_state, bot, game_state, config)
          |> Map.put(:chase_timer, 0)

        danger_zone and not playable_radius_closed ->
          %{angle_direction_to_entity: angle} = hd(enemies_by_distance)
          flee_angle_direction = if angle <= 0, do: angle + 180, else: angle - 180
          Map.put(bot_state, :action, {:move, flee_angle_direction})

        true ->
          Map.put(bot_state, :action, {:try_attack, closest_enemy, "1"})
      end

    Map.put(new_state, :chase_timer, new_state.chase_timer + @chase_timer_adittive)
  end

  defp decide_action(
         %{objective: :flee_from_zone} = bot_state,
         bot_id,
         players,
         state,
         _closest_entities
       ) do
    bot = Enum.find(players, fn player -> player.id == bot_id end)

    target =
      calculate_circle_point(
        bot.position,
        state.game_state.shrinking_center,
        false
      )

    Map.put(bot_state, :action, {:move, target})
  end

  defp decide_action(bot_state, _bot_id, _state, _game_state, _closest_entities) do
    bot_state
    |> Map.put(:action, {:nothing, nil})
  end

  defp do_action(connection_pid, _state, %{action: {:move, angle}}, _bot_id) do
    send(connection_pid, {:move, angle})
  end

  defp do_action(
         connection_pid,
         %{config: config, game_state: game_state},
         %{
           action: {:try_attack, %{type: :enemy, attacking_angle_direction: angle} = closest_enemy, skill_key}
         },
         bot_id
       ) do
    bot = Enum.find(game_state.players, fn player -> player.id == bot_id end)

    if skill_would_hit?(bot, closest_enemy, config, skill_key) do
      # Replace this when more abilities are implemented
      send(connection_pid, {:use_skill, angle, "BasicAttack"})
    else
      send(connection_pid, {:move, angle})
    end
  end

  defp do_action(_connection_pid, _state, _, _bot_id) do
    nil
  end

  ####################
  # Internal helpers #
  ####################
  def calculate_circle_point(%{x: start_x, y: start_y}, %{x: end_x, y: end_y}, use_inaccuracy) do
    calculate_circle_point(start_x, start_y, end_x, end_y, use_inaccuracy)
  end

  def calculate_circle_point(cx, cy, x, y, use_inaccuracy) do
    Nx.atan2(x - cx, y - cy)
    |> maybe_add_inaccuracy_to_angle(use_inaccuracy)
    |> Nx.multiply(Nx.divide(180.0, Nx.Constants.pi()))
    |> Nx.to_number()
    |> Kernel.*(-1)
  end

  def decide_objective(bot_state, %{bots_enabled: false}, _bot_id, _closest_entities) do
    Map.put(bot_state, :objective, :nothing)
  end

  def decide_objective(bot_state, %{game_state: game_state, config: config}, bot_id, %{
        enemies_by_distance: enemies_by_distance,
        loots_by_distance: loots_by_distance
      }) do
    bot = Enum.find(game_state.players, fn player -> player.id == bot_id end)

    closests_entities = [List.first(enemies_by_distance), List.first(loots_by_distance)]

    closest_entity = Enum.min_by(closests_entities, fn e -> if e, do: e.distance_to_entity end)

    center = game_state.shrinking_center
    radius = game_state.playable_radius

    out_of_area? = position_out_of_radius?(bot.position, center, radius)

    if out_of_area? do
      Map.put(bot_state, :objective, :flee_from_zone)
    else
      set_objective(bot_state, bot, game_state, config, closest_entity)
    end
  end

  def decide_objective(bot_state, _, _, _), do: Map.put(bot_state, :objective, :nothing)

  defp set_objective(bot_state, nil, _game_state, _config, _closest_entities),
    do: Map.put(bot_state, :objective, :waiting_game_update)

  defp set_objective(bot_state, bot, game_state, config, nil) do
    maybe_put_wandering_position(bot_state, bot, game_state, config)
  end

  defp set_objective(bot_state, _bot, _game_state, _config, closest_entity) do
    cond do
      bot_state.objective == :wander and bot_state.chase_timer > 0 ->
        Map.put(bot_state, :chase_timer, bot_state.chase_timer - @chase_timer_adittive)

      random_decision = maybe_random_decision() ->
        Map.put(bot_state, :objective, random_decision)

      closest_entity.type == :enemy ->
        Map.put(bot_state, :objective, :chase_enemy)

      closest_entity.type == :loot ->
        Map.put(bot_state, :objective, :chase_loot)
    end
  end

  defp get_closest_entities(_, nil), do: %{}

  defp get_closest_entities(game_state, bot) do
    # TODO maybe we could add a priority to the entities.
    # e.g. if the bot has low health priorities the loot boxes
    enemies_by_distance =
      game_state.players
      |> Enum.filter(fn player -> player.status == :alive and player.id != bot.id end)
      |> map_entities(bot, :enemy)

    loots_by_distance =
      game_state.loots
      |> map_entities(bot, :loot)

    %{
      enemies_by_distance: enemies_by_distance,
      loots_by_distance: loots_by_distance
    }
  end

  defp get_distance_to_point(%{x: start_x, y: start_y}, %{x: end_x, y: end_y}) do
    diagonal_movement_cost = 14
    straight_movement_cost = 10

    x_distance = abs(end_x - start_x)
    y_distance = abs(end_y - start_y)
    remaining = abs(x_distance - y_distance)

    (diagonal_movement_cost * Enum.min([x_distance, y_distance]) +
       remaining * straight_movement_cost)
    |> div(10)
  end

  defp map_entities(entities, bot, type) do
    entities
    |> Enum.map(fn entity ->
      %{
        type: type,
        entity_id: entity.id,
        distance_to_entity: get_distance_to_point(bot.position, entity.position),
        angle_direction_to_entity: calculate_circle_point(bot.position, entity.position, false),
        attacking_angle_direction: calculate_circle_point(bot.position, entity.position, true),
        entity_position: entity.position
      }
    end)
    |> Enum.sort_by(fn distances -> distances.distance_to_entity end, :asc)
    |> Enum.filter(fn distances -> distances.distance_to_entity <= @visibility_max_range_cells end)
  end

  defp skill_would_hit?(bot, %{distance_to_entity: distance_to_entity}, config, skill_key) do
    skill_range = Map.get(map_skills_range(bot.character_name, config), skill_key)
    range_modifier = :rand.uniform(@random_factor) * Enum.random([-1, 1])
    distance_to_entity < skill_range + range_modifier
  end

  def maybe_put_wandering_position(
        %{objective: :wander, current_wandering_position: current_wandering_position} = bot_state,
        bot,
        game_state,
        config
      ) do
    if get_distance_to_point(bot.position, %{
         x: current_wandering_position.x,
         y: current_wandering_position.y
       }) <
         500 do
      put_wandering_position(bot_state, bot, game_state, config)
    else
      bot_state
    end
  end

  def maybe_put_wandering_position(bot_state, bot, game_state, config),
    do: put_wandering_position(bot_state, bot, game_state, config)

  def put_wandering_position(
        bot_state,
        %{position: bot_position},
        game_state,
        config
      ) do
    bot_visibility_radius = @visibility_max_range_cells * 2

    # We need to pick and X and Y wich are in a safe zone close to the bot that's also inside of the board
    left_x =
      Enum.max([
        game_state.shrinking_center.x - game_state.playable_radius,
        bot_position.x - bot_visibility_radius,
        0
      ])

    right_x =
      Enum.min([
        game_state.shrinking_center.x + game_state.playable_radius,
        bot_position.x + bot_visibility_radius,
        get_in(config, ["game", "width"])
      ])

    down_y =
      Enum.max([
        game_state.shrinking_center.y - game_state.playable_radius,
        bot_position.y - bot_visibility_radius,
        0
      ])

    up_y =
      Enum.min([
        game_state.shrinking_center.y + game_state.playable_radius,
        bot_position.y + bot_visibility_radius,
        get_in(config, ["game", "height"])
      ])

    wandering_position = %{
      x: Enum.random(left_x..right_x),
      y: Enum.random(down_y..up_y)
    }

    Map.merge(bot_state, %{current_wandering_position: wandering_position, objective: :wander})
  end

  defp set_correct_wander_state(nil, bot_state), do: Map.put(bot_state, :action, {:nothing, nil})

  defp set_correct_wander_state(
         bot,
         %{current_wandering_position: wandering_position} = bot_state
       ) do
    target =
      calculate_circle_point(
        bot.position,
        wandering_position,
        false
      )

    Map.put(bot_state, :action, {:move, target})
  end

  defp position_out_of_radius?(position, center, playable_radius) do
    distance = get_distance_to_point(position, center)

    # We'll substract a fixed value to the playable radio to have some space between the bot
    # and the unplayable zone to avoid being on the edge of both
    distance > playable_radius - @radius_sub_to_escape
  end

  def maybe_random_decision() do
    case :rand.uniform(100) do
      x when x <= div(@random_factor, 8) ->
        :nothing

      x when x < div(@random_factor, 4) ->
        :wander

      _ ->
        nil
    end
  end

  defp maybe_add_inaccuracy_to_angle(angle, false), do: angle

  defp maybe_add_inaccuracy_to_angle(angle, true) do
    Nx.add(angle, Enum.random(0..@random_factor) / 100 * Enum.random([-1, 1]))
  end

  # This method will traverse the list of mechanics from the ability number 1
  # from the bot's character and check if we can get a range from any mechanic
  # and take the max of they in case more than one is found

  # Maybe we should a better way to get this value since this will force to every skill to
  # have a variabel "Range" in order to work, and if we would add a new range type variable
  # we would need to update this.

  # It returns 0 if no range is found
  defp map_skills_range(character_name, config) do
    character_name = String.downcase(character_name)

    bot_skills =
      config["characters"]
      |> Enum.find(fn character -> character["name"] == character_name end)
      |> Map.get("skills")

    Enum.reduce(bot_skills, %{}, fn {skill_key, skill_name}, acc ->
      skill_range =
        config["skills"]
        |> Enum.find(fn skill -> skill["name"] == skill_name end)
        |> Map.get("mechanics")
        |> hd()
        |> Map.to_list()
        |> get_max_skill_range(0)

      Map.put(acc, skill_key, skill_range)
    end)
  end

  defp get_max_skill_range([{_name, skill_mechanic}], acc) do
    range = Map.get(skill_mechanic, "range") || 0

    max(acc, range)
  end

  defp get_max_skill_range([{_name, skill_mechanic} | tail], acc) do
    range = Map.get(skill_mechanic, "range") || 0

    get_max_skill_range(tail, max(acc, range))
  end

  def random_chance(chance \\ 100, additive)

  def random_chance(chance, additive) do
    :rand.uniform(chance) <= @random_factor + additive
  end
end
