require "./Go/*"
require "kemal"
require "json"

require "db"
require "sqlite3"

URL = "localhost"
PORT = "3000"
GAME_CACHE = {} of String => Go::Game
GAME_SAVE  = "./game_saves.db"

def save_game(db, gameid, game)
    # Function: save_game
    # Parameters: db(String)[Unused] gameid(String) game(Go::Game)
    turn, size, white_pass, black_pass, board = game.encode
    DB.open "sqlite3:./#{GAME_SAVE}" do |db|
        # Create table if one does not exist, gameid is UNIQUE => No duplicates
        db.exec "create table if not exists game_saves (gameid string, turn integer, size integer, white_pass string, black_pass string, board string, UNIQUE(gameid) )"
        # If duplicate => replace values, else => make new row for gameid
        db.exec "insert or replace into game_saves values (?, ?, ?, ?, ?, ?)", gameid, turn.value, size, white_pass, black_pass, board
    end
end

def query_game(db, gameid) : Go::Game?
    # Function: query_game
    # Parameters: db(String)[Unused] gameid(String)
    turn       = 0
    size       = Go::Size::Small 
    white_pass = ""
    black_pass = ""
    board      = ""
    begin 
    DB.open "sqlite3:./#{GAME_SAVE}" do |db|
        # Query whole row where the gameid is found
        db.query "SELECT * FROM game_saves WHERE gameid = ?", gameid do |rs|
            rs.each do
                id         = rs.read(String) # Reduntant
                turn       = rs.read(Int32)
                size       = rs.read(Int32)
                white_pass = rs.read(String)
                black_pass = rs.read(String)
                board      = rs.read(String)
            end
        end
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
            x = counter % 9
            y = counter / 9
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
        puts "DB query Failed"
        return nil
    end
    # Finished Go::Game object to return
    return game
end

def lookup_game(db, cache, id) : Go::Game?
    # Function: lookup_game
    # Parameters: db(String)[Unused] cache({(String), (Go::Game)}) id(String)
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
    # Function: create_game
    # Parameters: db(String)[Unused] cache({(String), (Go::Game)}) game(Go::Game) id(String)
    cache[id] = game
end

def handle_message(id, game, socket, message)
    # Function: handle_message
    # Parameters: id(String) game(Go::Game) socket() message()
    
    split_command = message.split(" ")
    command = split_command[0]
    if command == "place"
        x = split_command[1].to_i8
        y = split_command[2].to_i8
        color = split_command[3] == "Black" ? Go::Color::Black : Go::Color::White

        game.update(x, y, color)
        game.sockets.each { |socket| socket.send game.to_json }
    end
end

get "/" do |env|
    render "src/Go/views/index.ecr", "src/Go/views/base.ecr"
end

get "/save" do |env|
    GAME_CACHE.each do |game_hash|
        gameid, game = game_hash
        save_game("none", gameid, game) 
    end
end


post "/game" do |env|
    game_id = env.params.body["id"]?
    game_password = env.params.body["password"]?
    if game_id == nil || game_password == nil
        render_404
    elsif game = lookup_game(nil, GAME_CACHE, game_id)
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
    elsif game = lookup_game(nil, GAME_CACHE, game_id)
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
    if game = lookup_game(nil, GAME_CACHE, game_id)
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

Kemal.run