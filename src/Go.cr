require "./Go/*"
require "kemal"
require "json"

require "db"
require "sqlite3"

URL = "localhost"
PORT = "3000"
GAME_CACHE = {} of String => Go::Game
GAME_SAVE  = "./game_saves.db"
GAME_DB = DB.open "sqlite3:./#{GAME_SAVE}"

def make_table(db)
    # Function:   make_table
    # Parameters: db(Sqlite)
    # Returns:    None
    db.exec "create table if not exists game_saves (
        gameid string, turn integer, size integer, white_pass string, 
        black_pass string, time string,  board string, UNIQUE(gameid) )"
end

def save_game(db, gameid, game)
    # Function:   save_game
    # Parameters: db(Sqlite) gameid(String) game(Go::Game)
    # Returns:    None
    turn, size, white_pass, black_pass, board = game.encode
    # If duplicate => replace values, else => make new row for gameid
    db.exec "insert or replace into game_saves values (?, ?, ?, ?, ?, ?, ?)", 
        gameid, turn.value, size, white_pass, black_pass, Time.now.to_json, board
end

def save_all(cache)
    # Function:   save_all
    # Parameters: cache({(String),(Go::Game)})
    # Returns:    None
    cache.each do |game_hash|
        gameid, game = game_hash
        save_game(GAME_DB, gameid, game) 
    end
end

def query_game(db, gameid) : Go::Game?
    # Function:   query_game
    # Parameters: db(Sqlite) gameid(String)
    # Returns:    (Go::Game) for a given gameid
    turn       = 0 
    size       = 9
    white_pass = ""
    black_pass = ""
    board      = ""
    begin 
        # Query whole row where the gameid is found
        db.query "SELECT turn,size,white_pass,black_pass,board FROM game_saves WHERE gameid = ?", gameid do |rs|
            rs.each do
                turn       = rs.read(Int32)
                size       = rs.read(Int32)
                white_pass = rs.read(String)
                black_pass = rs.read(String)
                board      = rs.read(String)
            end
        end
        if ( board == "" )
            return nil
        end
        # New Go::Game object
        game            = Go::Game.new()
        game.size       = Go::Size.from_value(size)
        game.white_pass = white_pass
        game.black_pass = black_pass
        game.turn       = Go::Color.from_value(turn)
        # Parses game board string
        counter = 0
        # For each character in the board String
        board.each_char do |char|
            x = counter / 9
            y = counter % 9
            coord = {x.to_i8, y.to_i8}
            if(char == 'B')
                game.board[coord] = Go::Color::Black
            elsif(char == 'W')
                game.board[coord] = Go::Color::White
            end
            counter += 1
        end
    rescue
        # Catch bad query
        return nil
    end
    # Finished Go::Game object to return
    return game
end

def game_cleaner(db, cache)
    # Function:    game_cleaner
    # Parameters:  db(Sqlite) cache({(String),(Go::Game)})
    # Returns:     None
    # Description: Cleans the database and memory of games older than 24 hours, every 2 hours
    spawn do
        loop do
            gameid = ""
            ntime  = Time.now()
            # Time span, for the subtraction of two time objects
            tspan = Time::Span.new(0,0,0)
            db.query "SELECT time, gameid FROM game_saves" do |rs|
                rs.each do
                    stime  = Time.from_json(rs.read(String))
                    gameid = rs.read(String)
                    tspan  = ntime - stime
                end
            end
            if( tspan.hours > 24 || tspan.days > 0 )
                # Delete game from database
                db.exec("DELETE FROM game_saves WHERE gameid = ?", gameid)
                # Delete game from memory
                cache.delete(gameid)
                puts "Game: #{gameid} deleted due to inactivity"
            end
            sleep 2.hour
        end
    end
end

def lookup_game(db, cache, id) : Go::Game?
    # Function:    lookup_game
    # Parameters:  db(Sqlite) cache({(String), (Go::Game)}) id(String)
    # Returns:     None
    # Description: Loads game data from memory, then attempts load from database
    if game = cache[id]?
        return game
    else
        loaded_game = query_game(db, id)
        # Need to convert id to string for some reason
        cache[id.to_s] = loaded_game if loaded_game
        return loaded_game
    end
end

def create_game(db, cache, game, id)
    # Function:   create_game
    # Parameters: db(Sqlite) cache({(String), (Go::Game)}) game(Go::Game) id(String)
    # Returns:    None
    cache[id] = game
end

def handle_message(id, game, socket, message)
    # Function:    handle_message
    # Parameters:  id(String) game(Go::Game) socket(WebSocket) message(String)
    # Returns:     None
    # Description: Handle placement messages from the WebSocket
    split_command = message.split(" ")
    command = split_command[0]
    if command == "place"
        x = split_command[1].to_i8
        y = split_command[2].to_i8
        color = split_command[3] == "Black" ? Go::Color::Black : Go::Color::White

        game.update(x, y, color)
        game.sockets.each { |socket| socket.send game.to_json }
        # If saving game on move
        save_game(GAME_DB, id, game)
    end
end

get "/about" do |env|
    render "src/Go/views/about.ecr"
end

get "/" do |env|
    render "src/Go/views/index.ecr", "src/Go/views/base.ecr"
end

post "/game" do |env|
    game_id = env.params.body["id"]?
    game_password = env.params.body["password"]?
    if game_id == nil || game_password == nil
        render_404
    elsif game = lookup_game(GAME_DB, GAME_CACHE, game_id)
        id = game_id
        size = game.size.value
        black = nil

        if game_password == game.black_pass
            black = true
        elsif game_password == game.white_pass
            black = false
        end

        black.try { |black| render "src/Go/views/game.ecr", "src/Go/views/base.ecr"} || render_404
    else
        render_404
    end
end

post "/create" do |env|
    game_id = env.params.body["id"]?
    user_password = env.params.body["your-password"]?
    other_password = env.params.body["their-password"]?
    color = env.params.body["color"]?

    color_e = nil
    if color == "black"
        color_e = Go::Color::Black
    elsif color == "white"
        color_e = Go::Color::White
    end

    if game_id == nil || user_password == nil || other_password == nil || color == nil || color_e == nil
        render_404
    elsif game = lookup_game(GAME_DB, GAME_CACHE, game_id)
        render_404
    else
        color_e = color_e.as(Go::Color)
        user_password = user_password.as(String)
        other_password = other_password.as(String)
        if color_e == Go::Color::Black
            white_pass, black_pass = other_password, user_password
        else
            white_pass, black_pass = user_password, other_password
        end
        game = Go::Game.new(Go::Size::Small, black_pass, white_pass)
        create_game(nil, GAME_CACHE, game, game_id.as(String))   

        id = game_id
        size = game.size.value
        black = color_e == Go::Color::Black
        render "src/Go/views/game.ecr", "src/Go/views/base.ecr"
    end
end

ws "/game/:id" do |socket, env|
    game_id = env.params.url["id"]
    if game = lookup_game(GAME_DB, GAME_CACHE, game_id)
        socket.send game.to_json
        game.sockets << socket

        socket.on_message do |message|
            game.try { |game| handle_message(game_id, game, socket, message) }
        end

        socket.on_close do 
            game.try { |game| game.sockets.delete socket }
        end
    else
        render_404
    end
end

# For timed-autosave
# spawn do
#     loop do
#         sleep 10.minute
#         save_all(GAME_CACHE)
#     end
# end

# If table does not exist, build it
make_table(GAME_DB)
# Remove games that are older than 24hrs
game_cleaner(GAME_DB, GAME_CACHE)
Kemal.run

# If exit is disabled in kemal.stop
# For save on close
# at_exit do
#     save_all(GAME_CACHE)
# end
