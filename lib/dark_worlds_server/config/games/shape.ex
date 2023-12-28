defmodule DarkWorldsServer.Config.Games.Shape do
  use Ecto.Type

  def type(), do: :string

  def cast({:rectangle, %{width: width, height: height}}),
    do: {:ok, %{"width" => width, "height" => height}}

  def cast({:circle, %{radius: radius}}), do: {:ok, %{"radius" => radius}}

  def load(string), do: {:ok, shape_from_string(string)}

  def dump(shape), do: {:ok, shape_to_string(shape)}

  defp shape_to_string(shape) do
    case shape do
      %{"width" => width, "height" => height} ->
        "Rectangle,#{width},#{height}"

      %{"radius" => radius} ->
        "Circle,#{radius}"
    end
  end

  defp shape_from_string(string) do
    case String.split(string, ",") do
      ["Rectangle", width, height] ->
        {:rectangle, %{width: width, height: height}}

      ["Circle", radius] ->
        {:circle, %{ radius: radius}}

      _ ->
        "Invalid"
    end
  end
end
