module Go
    enum Color
        Black
        White
    end

    enum Size
        Small = 9,
        Medium = 13,
        Large = 19
    end

    alias Board = Hash(Tuple(Int8, Int8), Color)

    class Game
        property size : Size
        property black_pass : String
        property white_pass : String
        property board  : Board
        property turn : Color
        property sockets : Array(HTTP::WebSocket)

        def initialize()
            @size = Size::Small
            @white_pass = ""
            @black_pass = ""
            @board = Board.new
            @turn = Color::Black
            @sockets = [] of HTTP::WebSocket
        end
        def initialize(size : Size, @black_pass, @white_pass)
            @size = size
            @board = Board.new
            @turn = Color::Black
            @sockets = [] of HTTP::WebSocket
        end

        private def cell_json(index, color, json)
            json.object do
                json.field "index" do
                    json.object do
                        json.field "x", index[0]
                        json.field "y", index[1]
                    end
                end
                json.field "color", color.to_s
            end
        end

        private def board_json(board, json)
            json.array do
                board.each do |key, value|
                    cell_json(key, value, json)
                end
            end
        end

        def to_json
            JSON.build do |json|
                json.object do
                    json.field "turn", @turn.to_s
                    json.field "board" { board_json(@board, json) }
                end
            end
        end

        private def count_neighbors(x, y, color, visited)
            coord = {x, y}
            if visited.includes?(coord) || (x < 0 || x >= @size.value || y < 0 || y >= @size.value)
                return 0
            else
                visited.push(coord)
                case @board[coord]?
                when color
                    return count_neighbors(x - 1, y, color, visited) + 
                        count_neighbors(x + 1, y, color, visited) +
                        count_neighbors(x, y - 1, color, visited) +
                        count_neighbors(x, y + 1, color, visited)
                when nil
                    return 1
                else
                    return 0
                end
            end
            return 0
        end

        private def remove_color(x, y, color)
            coord = {x, y}
            if !(x < 0 || x >= @size.value || y < 0 || y >= @size.value) && @board[coord]? == color
                @board.delete(coord)
                remove_color(x - 1, y, color)
                remove_color(x + 1, y, color)
                remove_color(x, y - 1, color)
                remove_color(x, y + 1, color)
            end
        end

        private def try_remove_branch(x, y, color)
            coord = {x, y}
            if @board[coord]? == color
                neighbor_count = count_neighbors(x, y, color, [] of Tuple(Int8, Int8))
                if neighbor_count == 0
                    remove_color(x, y, color)
                end
            end
        end

        def invert(color)
            color == Color::Black ? Color::White : Color::Black
        end

        def update(x, y, color)
            coord = {x, y}
            if @turn == color
                @board[coord] = color
                new_color = invert(color)
                try_remove_branch(x - 1, y, new_color)
                try_remove_branch(x + 1, y, new_color)
                try_remove_branch(x, y - 1, new_color)
                try_remove_branch(x, y + 1, new_color)
                try_remove_branch(x, y, color)
                @turn = new_color
            end
        end

        private def color_char(color)
            color == Color::Black ? 'B' : 'W'
        end

        private def board_string(board)
            String.build do |str|
                (0...@size.value).each do |x|
                    (0...@size.value).each do |y|
                        color = @board[{x.to_i8, y.to_i8}]?
                        char = color ? color_char(color) : 'E'
                        str << char
                    end
                end
            end
        end

        def encode
            { @turn, @size.value, @white_pass.to_s, @black_pass.to_s, board_string(@board) }
        end
    end
end
