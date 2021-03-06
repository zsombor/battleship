# Insight found from:
# [Nick Berry](http://www.datagenetics.com/blog/december32011/) and
# [Keith Randall](http://stackoverflow.com/questions/1631414/what-is-the-best-battleship-ai)

# Playing Strategy
# * Hunt Mode - "randomly" until a ship is hit, with the restrictions:
#     * Parity filtering: while the destroyer is alive, do not shoot in
#       destroyer range of known misses...once sunk, do not shoot within
#       cruiser range of known misses... etc.
#     * Background probability: also weight center tiles the most of the
#       remaining valid spaces
# * Target Mode - Each time a ship is hit, calculate all of the possible
#   arrangements of the remaining ships on the board, and fire on the next
#   most probable spot until that ship is sunk. Then return to Hunt mode.

require 'set'
require 'matrix'

class EdenPlayer
  # saves state of shooting strategy
  attr_accessor :hunting
  # state of emey's ships are needed to notice when one sunk
  attr_accessor :opponents_ships
  attr_accessor :last_hit, :last_board

  ACROSS = Vector[1, 0]
  DOWN = Vector[0, 1]

  def initialize
    @hunting = true
    @opponents_ships = [5, 4, 3, 3, 2]
    @last_board = EdenPlayer.new_board
  end

  # Uniquely identifies President Eden
  def name
    "Eden"
  end

  # returns where to lay Eden's ships at the start of a new game
  def new_game
    my_board = EdenPlayer.new_board
    ships = [5, 4, 3, 3, 2]
    probs = positional_probabilities my_board
    ship_pos = ships.map do |ship|
      laid = nil
      until laid
        rand_branch = rand(999) % 3
        # 1/3rd of the time, don't lay the ship in lowest probability spot
        # near edge, this gives a grouping formation that gives a few ships
        # a great area that they may be found in
        pos = rand(999) % 3 == 1 ? [rand(10), rand(10)] : draw_next_min(probs)
        laid = lay_ship({ship_length: ship, board: my_board, pos: pos})
      end
      laid
    end
  end

  def take_turn(state, ships_remaining)
    update_state!(state, ships_remaining)
    if @hunting
      next_hunting_point(state)
    else
      next_target_point(state, ships_remaining, @last_hit)
    end
  end

  # in charge of switching between hunting and targetting modes by detecting
  # both new hits and new sunk ships. Mutates state.
  def update_state!(new_board, ships_remaining)
    if (hit = detect_hit(@last_board, new_board))
      @hunting = false
      @last_hit = hit
    end
    unless ships_remaining.sort == @opponents_ships.sort
      @hunting, @opponents_ships = [true, ships_remaining]
    end
    @last_board = new_board
  end

  # detects differences between boards
  def detect_hit(old_state, new_state)
    new_state.each_with_index do |row, y|
      next if row == old_state[y]
      row.each_with_index do |sym, x|
        next if sym == old_state[y][x]
        return [x, y] if sym == :hit
      end
    end
    nil
  end

  def lay_ship(options = {})
    dirs = [{down: DOWN}, {across: ACROSS}]
    until dirs.empty?
      rand_dir = dirs.delete dirs.sample
      body = body_from_head options[:pos], options[:ship_length], rand_dir.values.first
      if valid? body, options[:board]
        # modifies the board
        fill_game_board(options[:board], :taken, body)
        return [*options[:pos], options[:ship_length], rand_dir.keys.first]
      end
    end
  end

  def next_target_point(state, ships, pos)
    sum_probs = aggregate_targets(state, ships, pos)
    max = sum_probs.to_a.flatten.max
    sum_probs.index(max).to_a.reverse
  end

  def aggregate_targets(state, ships, pos)
    sum_probs = ships.inject(EdenPlayer.prob_board_matrix) do |a,e|
      a + probable_enemy_occupations(ship_length: e, pos: pos, board: state)
    end
    sum_probs
  end

  # This method is used for evaluating where a ship could be on the board
  # after a part of that ship has been hit. It returns a matrix representation
  # of the board with each square filled with the number of orientations that
  # a ship could occupy that square on the board
  def probable_enemy_occupations(options = {})
    fail 'Position not given!' unless options[:pos]
    # starting with the rightmost...leftmost. Then bottommost...topmost
    occupation_points = []
    center = Vector[*options[:pos]]
    # horizontally, until ship goes too left
    head = center.dup
    until head == center + Vector[-(options[:ship_length]), 0]
      body = body_from_head(head, options[:ship_length], ACROSS)
      occupation_points << body if valid?(body, options[:board])
      head -= ACROSS
    end
    # vertically, again until ship goes too far up
    head = center.dup
    until head == center + Vector[0, -(options[:ship_length])]
      body = body_from_head(head, options[:ship_length], DOWN)
      occupation_points << body if valid?(body, options[:board])
      head -= DOWN
    end
    points = remove_invalid_shots!(occupation_points.flatten, options[:board])
    EdenPlayer.prob_board_matrix points
  end

  def body_from_head(head, length, direction)
    head = Vector[*head] unless head.is_a? Vector
    (0...length).map { |i| head + (i * direction) }
  end

  def remove_invalid_shots!(array_of_vect, board)
    array_of_vect.map do |coord|
      x, y = [coord[0], coord[1]]
      next unless board[y][x] == :unknown
      coord
    end.compact
  end

  def valid?(body, board)
    body.each do |coord|
      x, y = [coord[0], coord[1]]
      return false unless x >= 0 && x <= 9 && y >= 0 && y <= 9
      return false unless board[y][x] == :unknown || board[y][x] == :hit
    end
    true
  end

  def next_hunting_point(board)
    probs = positional_probabilities(board)
    probs.max_by { |h| h[:rank] }[:pos].to_a
  end

  # specifically for narrowing down points for laying ships
  def draw_next_min(prob_set)
    min = prob_set.min_by { |h| h[:rank] }
    prob_set.delete min
    min[:pos]
  end

  # given a board, create a set containing points and ranks of likeliness
  def positional_probabilities(board)
    bg_probs = Set.new
    miss_coords = []
    board.each_with_index do |row, y|
      row.each_with_index do |e, x|
        # on average, ships are more likely to be in the center
        if e == :unknown
          bg_probs << {pos: Vector[x, y], rank: middleness(x) * middleness(y) }
        elsif e == :miss
          miss_coords << Vector[x, y]
        end
      end
    end
    skew_probs_near_misses! bg_probs, miss_coords, board
  end

  # annotate the board with zero probabilities for squares within a
  # ship's reach of a missed square
  def skew_probs_near_misses!(set_of_probs, miss_coords, board)
    miss_coords.each do |miss_coord|
      around = [ACROSS, -1 * ACROSS, DOWN, -1 * DOWN]
      range = @opponents_ships.min - 1
      (1..range).each do |range_unit|
        # we will throw out each near_miss, unless it is next to a hit square
        around.each do |transformation|
          near_miss_coord = (range_unit * transformation) + miss_coord
          near_miss = set_of_probs.detect { |p| p[:pos] == near_miss_coord }
          # will only find unknowns in the set
          next unless near_miss
          # check if near_miss is adjacent to a hit square
          near_hits = around.any? do |trans|
            x, y = (trans + near_miss_coord).to_a
            # lazy checking of out of bounds, should really have a valid? method
            board[y][x] == :hit if board[y]
          end
          near_miss[:rank] = (near_hits ? 0 : -1)
        end
      end
    end
    set_of_probs
  end

  # weight middle of the battleship board higher
  # return a higher output number when the input number is closer to 5
  def middleness(num)
    ((num - 5).abs - 6).abs
  end

  def self.new_board
    Array.new(10) { Array.new(10) { :unknown } }
  end

  def self.prob_board_matrix(coords_to_fill = [])
    board = Array.new(10) { Array.new(10) { 0 } }
    coords_to_fill.each do |coord|
      x, y = [coord[0], coord[1]]
      board[y][x] += 1
    end
    Matrix[*board]
  end

  def fill_game_board(board, symbol, arr_coords)
    arr_coords.each do |coord|
      x, y = [coord[0], coord[1]]
      board[y][x] = symbol
    end
    board
  end
end