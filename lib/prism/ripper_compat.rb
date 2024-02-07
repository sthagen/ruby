# frozen_string_literal: true

require "ripper"

module Prism
  # Note: This integration is not finished, and therefore still has many
  # inconsistencies with Ripper. If you'd like to help out, pull requests would
  # be greatly appreciated!
  #
  # This class is meant to provide a compatibility layer between prism and
  # Ripper. It functions by parsing the entire tree first and then walking it
  # and executing each of the Ripper callbacks as it goes.
  #
  # This class is going to necessarily be slower than the native Ripper API. It
  # is meant as a stopgap until developers migrate to using prism. It is also
  # meant as a test harness for the prism parser.
  #
  # To use this class, you treat `Prism::RipperCompat` effectively as you would
  # treat the `Ripper` class.
  class RipperCompat < Visitor
    # This class mirrors the ::Ripper::SexpBuilder subclass of ::Ripper that
    # returns the arrays of [type, *children].
    class SexpBuilder < RipperCompat
      private

      Ripper::PARSER_EVENTS.each do |event|
        define_method(:"on_#{event}") do |*args|
          [event, *args]
        end
      end

      Ripper::SCANNER_EVENTS.each do |event|
        define_method(:"on_#{event}") do |value|
          [:"@#{event}", value, [lineno, column]]
        end
      end
    end

    # This class mirrors the ::Ripper::SexpBuilderPP subclass of ::Ripper that
    # returns the same values as ::Ripper::SexpBuilder except with a couple of
    # niceties that flatten linked lists into arrays.
    class SexpBuilderPP < SexpBuilder
      private

      def _dispatch_event_new # :nodoc:
        []
      end

      def _dispatch_event_push(list, item) # :nodoc:
        list << item
        list
      end

      Ripper::PARSER_EVENT_TABLE.each do |event, arity|
        case event
        when /_new\z/
          alias_method :"on_#{event}", :_dispatch_event_new if arity == 0
        when /_add\z/
          alias_method :"on_#{event}", :_dispatch_event_push
        end
      end
    end

    # The source that is being parsed.
    attr_reader :source

    # The current line number of the parser.
    attr_reader :lineno

    # The current column number of the parser.
    attr_reader :column

    # Create a new RipperCompat object with the given source.
    def initialize(source)
      @source = source
      @result = nil
      @lineno = nil
      @column = nil
    end

    ############################################################################
    # Public interface
    ############################################################################

    # True if the parser encountered an error during parsing.
    def error?
      result.failure?
    end

    # Parse the source and return the result.
    def parse
      result.magic_comments.each do |magic_comment|
        on_magic_comment(magic_comment.key, magic_comment.value)
      end

      if error?
        result.errors.each do |error|
          on_parse_error(error.message)
        end

        nil
      else
        result.value.accept(self)
      end
    end

    ############################################################################
    # Visitor methods
    ############################################################################

    # Visit an ArrayNode node.
    def visit_array_node(node)
      elements = visit_elements(node.elements) unless node.elements.empty?
      bounds(node.location)
      on_array(elements)
    end

    # Visit a CallNode node.
    # Ripper distinguishes between many different method-call
    # nodes -- unary and binary operators, "command" calls with
    # no parentheses, and call/fcall/vcall.
    def visit_call_node(node)
      if node.variable_call?
        raise NotImplementedError unless node.receiver.nil?

        bounds(node.message_loc)
        return on_vcall(on_ident(node.message))
      end

      if node.opening_loc.nil?
        return visit_no_paren_call(node)
      end

      # A non-operator method call with parentheses
      args = on_arg_paren(node.arguments.nil? ? nil : args_node_to_arguments(node.arguments))

      bounds(node.message_loc)
      ident_val = on_ident(node.message)

      bounds(node.location)
      args_call_val = on_method_add_arg(on_fcall(ident_val), args)
      if node.block
        block_val = visit(node.block)

        return on_method_add_block(args_call_val, on_brace_block(nil, block_val))
      else
        return args_call_val
      end
    end

    # Visit a BlockNode
    def visit_block_node(node)
      if node.body.nil?
        on_stmts_add(on_stmts_new, on_void_stmt)
      else
        visit(node.body)
      end
    end

    # Visit an AndNode
    def visit_and_node(node)
      visit_binary_operator(node)
    end

    # Visit an OrNode
    def visit_or_node(node)
      visit_binary_operator(node)
    end

    # Visit a FloatNode node.
    def visit_float_node(node)
      visit_number(node) { |text| on_float(text) }
    end

    # Visit a ImaginaryNode node.
    def visit_imaginary_node(node)
      visit_number(node) { |text| on_imaginary(text) }
    end

    # Visit an IntegerNode node.
    def visit_integer_node(node)
      visit_number(node) { |text| on_int(text) }
    end

    # Visit a ParenthesesNode node.
    def visit_parentheses_node(node)
      body =
        if node.body.nil?
          on_stmts_add(on_stmts_new, on_void_stmt)
        else
          visit(node.body)
        end

      bounds(node.location)
      on_paren(body)
    end

    # Visit a ProgramNode node.
    def visit_program_node(node)
      statements = visit(node.statements)
      bounds(node.location)
      on_program(statements)
    end

    # Visit a RangeNode node.
    def visit_range_node(node)
      left = visit(node.left)
      right = visit(node.right)

      bounds(node.location)
      if node.exclude_end?
        on_dot3(left, right)
      else
        on_dot2(left, right)
      end
    end

    # Visit a RationalNode node.
    def visit_rational_node(node)
      visit_number(node) { |text| on_rational(text) }
    end

    # Visit a StatementsNode node.
    def visit_statements_node(node)
      bounds(node.location)
      node.body.inject(on_stmts_new) do |stmts, stmt|
        on_stmts_add(stmts, visit(stmt))
      end
    end

    ############################################################################
    # Entrypoints for subclasses
    ############################################################################

    # This is a convenience method that runs the SexpBuilder subclass parser.
    def self.sexp_raw(source)
      SexpBuilder.new(source).parse
    end

    # This is a convenience method that runs the SexpBuilderPP subclass parser.
    def self.sexp(source)
      SexpBuilderPP.new(source).parse
    end

    private

    # Generate Ripper events for a CallNode with no opening_loc
    def visit_no_paren_call(node)
      # No opening_loc can mean an operator. It can also mean a
      # method call with no parentheses.
      if node.message.match?(/^[[:punct:]]/)
        left = visit(node.receiver)
        if node.arguments&.arguments&.length == 1
          right = visit(node.arguments.arguments.first)

          return on_binary(left, node.name, right)
        elsif !node.arguments || node.arguments.empty?
          return on_unary(node.name, left)
        else
          raise NotImplementedError, "More than two arguments for operator"
        end
      elsif node.call_operator_loc.nil?
        # In Ripper a method call like "puts myvar" with no parenthesis is a "command".
        bounds(node.message_loc)
        ident_val = on_ident(node.message)

        # Unless it has a block, and then it's an fcall (e.g. "foo { bar }")
        if node.block
          block_val = visit(node.block)
          # In these calls, even if node.arguments is nil, we still get an :args_new call.
          method_args_val = on_method_add_arg(on_fcall(ident_val), args_node_to_arguments(node.arguments))
          return on_method_add_block(method_args_val, on_brace_block(nil, block_val))
        else
          args = node.arguments.nil? ? nil : args_node_to_arguments(node.arguments)
          return on_command(ident_val, args)
        end
      else
        operator = node.call_operator_loc.slice
        if operator == "." || operator == "&."
          left_val = visit(node.receiver)

          bounds(node.call_operator_loc)
          operator_val = operator == "." ? on_period(node.call_operator) : on_op(node.call_operator)

          bounds(node.message_loc)
          right_val = on_ident(node.message)

          call_val = on_call(left_val, operator_val, right_val)

          if node.block
            block_val = visit(node.block)
            return on_method_add_block(call_val, on_brace_block(nil, block_val))
          else
            return call_val
          end
        else
          raise NotImplementedError, "operator other than . or &. for call: #{operator.inspect}"
        end
      end
    end

    # Ripper generates an interesting format of argument list.
    # It seems to be very location-specific. We should get rid of
    # this method and make it clearer how it's done in each place.
    def args_node_to_arguments(args_node)
      return on_args_new if args_node.nil?

      args = visit_elements(args_node.arguments)

      on_args_add_block(args, false)
    end

    # Visit a list of elements, like the elements of an array or arguments.
    def visit_elements(elements)
      bounds(elements.first.location)
      elements.inject(on_args_new) do |args, element|
        on_args_add(args, visit(element))
      end
    end

    # Visit a node that represents a number. We need to explicitly handle the
    # unary - operator.
    def visit_number(node)
      slice = node.slice
      location = node.location

      if slice[0] == "-"
        bounds_values(location.start_line, location.start_column + 1)
        value = yield slice[1..-1]

        bounds(node.location)
        on_unary(visit_unary_operator(:-@), value)
      else
        bounds(location)
        yield slice
      end
    end

    if RUBY_ENGINE == "jruby" && Gem::Version.new(JRUBY_VERSION) < Gem::Version.new("9.4.6.0")
      # JRuby before 9.4.6.0 uses :- for unary minus instead of :-@
      def visit_unary_operator(value)
        value == :-@ ? :- : value
      end
    else
      # For most Rubies and JRuby after 9.4.6.0 this is a no-op.
      def visit_unary_operator(value)
        value
      end
    end

    # Visit a binary operator node like an AndNode or OrNode
    def visit_binary_operator(node)
      left_val = visit(node.left)
      right_val = visit(node.right)
      on_binary(left_val, node.operator.to_sym, right_val)
    end

    # This method is responsible for updating lineno and column information
    # to reflect the current node.
    #
    # This method could be drastically improved with some caching on the start
    # of every line, but for now it's good enough.
    def bounds(location)
      @lineno = location.start_line
      @column = location.start_column
    end

    # If we need to do something unusual, we can directly update the line number
    # and column to reflect the current node.
    def bounds_values(lineno, column)
      @lineno = lineno
      @column = column
    end

    # Lazily initialize the parse result.
    def result
      @result ||= Prism.parse(source)
    end

    def _dispatch0; end # :nodoc:
    def _dispatch1(_); end # :nodoc:
    def _dispatch2(_, _); end # :nodoc:
    def _dispatch3(_, _, _); end # :nodoc:
    def _dispatch4(_, _, _, _); end # :nodoc:
    def _dispatch5(_, _, _, _, _); end # :nodoc:
    def _dispatch7(_, _, _, _, _, _, _); end # :nodoc:

    alias_method :on_parse_error, :_dispatch1
    alias_method :on_magic_comment, :_dispatch2

    (Ripper::SCANNER_EVENT_TABLE.merge(Ripper::PARSER_EVENT_TABLE)).each do |event, arity|
      alias_method :"on_#{event}", :"_dispatch#{arity}"
    end
  end
end
