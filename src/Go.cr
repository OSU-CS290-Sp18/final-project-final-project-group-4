require "./Go/*"
require "kemal"
require "json"

require "db"
require "sqlite3"

URL = "localhost"
PORT = "3000"
GAME_CACHE = {} of String => Go::Game


def save_game(db, gameid, game)
    puts "Saving"
    puts game.encode
    turn, size, board = game.encode
    DB.open "sqlite3:./game_saves.db" do |db|
        # When using the pg driver, use $1, $2, etc. instead of ?
        #db.exec "create table game_saves (gameid integer, turn integer, size integer, board string )"
        db.exec "insert into game_saves values (?, ?, ?, ?)", gameid, turn, size, board
    end
end

def query_game(db, gameid) : Go::Game?

    DB.open "sqlite3:./game_saves.db" do |db|
        puts "contacts:"
        db.query "select gameid, turn, size, board from game_saves order by gameid desc" do |rs|
            rs.each do
                puts rs.size
                #puts "#{rs.read(Int32)} (#{rs.read(Int32)}) (#{rs.read(Int32)}) (#{rs.read(String)})"
            end
            puts rs
          # puts "#{rs.column_name(0)} (#{rs.column_name(1)})"
          #rs.each do
            #puts "#{rs.read(String)} (#{rs.read(Int32)})"
          #end
        end
      end
    return nil
end

def lookup_game(db, cache, id) : Go::Game?
    if game = cache[id]?
        return game
    else
        loaded_game = query_game(db, id)
        cache[id] = loaded_game if loaded_game
        return loaded_game
    end
end

def create_game(db, cache, game, id)
    cache[id] = game
end

def handle_message(id, game, socket, message)
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
    #game = Go::Game.new(Go::Size::Small, "asdf", "sadfasdf")
    #save_game(db, 0, game)
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

def test_save()
    puts "test"
    game = Go::Game.new(Go::Size::Small, "asdf", "sadfasdf")
    
    save_game("none", 1, game)
    query_game("none", 1)
end


test_save()
Kemal.run