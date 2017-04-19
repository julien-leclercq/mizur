defmodule Mizur do

  @moduledoc """
  **Mizur** is a tool to simplify the management, conversions  
  and mapping of units. 

  The manipulation of units of measurement try (at best) 
  to be typesafe.
  """

  @type metric_type :: {
    module, 
    atom, 
    boolean, 
    (number -> float),
    (number -> float)
  }

  @type typed_value :: {
    metric_type, 
    float
  }

  defmodule System do 

    @moduledoc """
    Sets up a metric system.

    This module must be used in another module to define a metric system.

    When used, it accepts the following options:

    - `:intensive` : defined a metric system as using intensive measurements.
       An intensive system prohibits arithmetic operations between units. 
       It only allows conversions.

    ## Example 

    ```
    defmodule Distance do 
      use Mizur.System

      type m # m is used as a reference
      type cm = m / 100 
      type mm = m / 1000 
      type km = m * 1000

    end
    ```
    """

    @doc false
    defmacro __using__(opts) do 
      quote do 
        import Mizur.System
        @basis nil
        @metrics []
        @before_compile Mizur.System
        @intensive !!unquote(opts)[:intensive]
      end
    end


    @doc false
    defmacro __before_compile__(_env) do
      quote do
        def system_metric do
          %{
            units: @metrics,
            intensive?: @intensive
          }
        end
      end
    end

    @doc false 
    def rev_operator(op) do 
      case op do 
        :+ -> :- 
        :- -> :+ 
        :* -> :/
        :/ -> :*
        _  -> 
          raise RuntimeError, 
            message: "#{op} is an unknown operator"
      end
    end

    @doc false 
    def revert_expr(acc, f_expr) do 
      expr = Macro.postwalk(
        f_expr, 
        fn(elt) -> 
          case elt do 
            {op, _, [a, b]} when is_number(a) and is_number(b) ->
              apply(Kernel, op, [a, b])
            _ -> elt
          end
        end
      )
      case expr do 
        {_, _, nil} -> acc
        {op, _, [left, right]} 
          when is_number(left) ->
            new_acc = {rev_operator(op), [], [acc, left]}
            revert_expr(new_acc, right)
        {op, _, [right, left]} 
          when is_number(left) ->
            new_acc = {rev_operator(op), [], [acc, left]}
            revert_expr(new_acc, right)
        {op, _, [left, {_, _, nil}]} ->
            {rev_operator(op), [], [acc, left]}
        {op, _, [{_, _, nil}, left]} ->
            {rev_operator(op), [], [acc, left]}
        _ -> 
          acc
      end
    end


    @doc false 
    defmacro create_lambda(expr) do 
      formatted = Macro.postwalk(expr, fn(elt) -> 
        case elt do 
          {x, _, nil} when is_atom(x) -> {:basis, [], __MODULE__}
          {x, _, t_elt} -> {x, [], t_elt}
          _ -> elt
        end
      end)
      quote do: (fn(basis) -> unquote(formatted) end)
    end

    @doc false 
    defmacro revert_lambda(expr) do 
      fexpr = revert_expr({:target, [], __MODULE__}, expr)
      formatted = Macro.postwalk(
        fexpr, 
        fn(elt) -> 
          case elt do 
            {x, _, nil} when is_atom(x) -> {:target, [], __MODULE__}
            {x, _, t_elt} -> {x, [], t_elt}
            _ -> elt
          end
        end
      )
      quote do: fn(target) -> unquote(formatted) end
    end
    

    @doc false
    defmacro define_basis(basis) do 


      quote do 

        @basis unquote(basis)
        @metrics [unquote(basis) | @metrics]


        def unquote(basis)() do 
          {
            __MODULE__, 
            unquote(basis),
            @intensive,
            fn(x) -> x * 1.0 end, # from_basis
            fn(x) -> x * 1.0 end  # to_basis
          }
        end

        def unquote(basis)(value) do 
          {
            apply(__MODULE__, unquote(basis), []),
            value * 1.0
          }
        end
        
      end
    end


    @doc false
    defmacro define_internal_type(name, expr) do 


      quote do 
        @metrics [unquote(name) | @metrics]

        def unquote(name)() do 
          {
            __MODULE__, 
            unquote(name), 
            @intensive,
            revert_lambda(unquote(expr)),   # from_basis 
            create_lambda(unquote(expr))    # to_basis
          }
        end

        def unquote(name)(value) do 
          {
            apply(__MODULE__, unquote(name), []),
            value * 1.0
          }
        end

      end
    end

    
    @doc """
    Defines the metric system reference unit. For example, 
    `m` in the distance system :

    ```
    defmodule Distance do 
      use Mizur.System

      type m # m is used as a reference
      type cm = m / 100 
      type mm = m / 1000 
      type km = m * 1000

    end
    ```

    - You can only use one reference unit.
    - In the expression to define the ratio between a unit 
      and its reference, only the reference can be used as variable 
      and the operators: `+`, `*`, `-` and `/`.

    """
    defmacro type({basis, _, nil}) do
      quote do
        case @basis do 
          nil -> define_basis(unquote(basis))
          _ -> 
            raise RuntimeError, 
              message: "Basis is already defined (#{@basis})"
        end
      end
    end

    defmacro type({:=, _, [{name, _, nil}, rest]}) do 
      quote do 
        case @basis do 
          nil -> 
            raise RuntimeError, 
              message: "Basis must be defined"
          _ -> 
            cond do 
              Enum.member?(@metrics, unquote(name)) ->
                raise RuntimeError, 
                  message: "#{unquote(name)} is already defined"
              true -> 
                define_internal_type(
                  unquote(name), 
                  unquote(rest)
                )  
            end
        end
      end
    end
    
    defmacro type(_value) do 
      raise RuntimeError, 
        message: "The line is unparsable"
    end


  end
  


  @doc """
  Retrieves the wrapped numeric value in a `typed_value`.

  For example: 
      iex> x = MizurTest.Distance.cm(12)
      ...> Mizur.unwrap(x)
      12.0
  """
  @spec unwrap(typed_value) :: float
  def unwrap({_, value}), do: value



  @doc """
  Converts a `typed_value` to another subtype of its metric system.

  For example: 
      iex> x = MizurTest.Distance.cm(120)
      ...> Mizur.from(x, to: MizurTest.Distance.m)
      {MizurTest.Distance.m, 1.2}
  """
  @spec from(typed_value, [to: metric_type]) :: typed_value
  def from({{module, _, _, _, to}, base}, to: {module, _, _, from, _} = t) do
    new_value = from.(to.(base))
    {t, new_value}
  end

  def from({{m, _, _, _, _},_}, to: {other_m, _, _, _, _}) do 
    message = "#{m} is not compatible with #{other_m}"
    raise RuntimeError, message: message
  end

  @doc """
  Infix version of `from/2`.

  For example:
      iex> import Mizur
      ...> MizurTest.Distance.cm(100) ~> MizurTest.Distance.m
      {MizurTest.Distance.m, 1.0}
  """
  @spec typed_value ~> metric_type :: typed_value
  def base ~> to do 
    from(base, to: to)
  end

  @doc """
  Applies a function to the numeric value of a typed value and re-packs
  the result of the function in the same subtype.
  For example:
      iex> MizurTest.Distance.km(120)
      ...> |> Mizur.map(fn(x) -> x * 2 end)
      {MizurTest.Distance.km, 240.0}
  """
  @spec map(typed_value, (number -> number)) :: typed_value 
  def map({type, elt}, f) do 
    {type, f.(elt)}
  end

  @doc """
  Applies a function to the two numeric values of two `typed_values()` in 
  the same metric system, and re-packages the result 
  of the function in a `typed_value()` of the subtype of the left `typed_values()`.
  For example: 
      iex> a = MizurTest.Distance.m(100)
      ...> b = MizurTest.Distance.km(2)
      ...> Mizur.map2(a, b, &(&1 * &2))
      {MizurTest.Distance.m, 200000.0}
  """
  @spec map2(typed_value, typed_value, (number, number -> number)) :: typed_value
  def map2({t, a}, elt2, f) do 
    {_, b } = elt2 ~> t 
    {t, f.(a, b)}
  end
  

end
