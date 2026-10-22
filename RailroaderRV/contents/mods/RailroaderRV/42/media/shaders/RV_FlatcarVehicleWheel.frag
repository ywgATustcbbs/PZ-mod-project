#version 110

varying vec3 vertColour;
varying vec3 vertNormal;
varying vec2 texCoords;

uniform sampler2D Texture;
uniform float Alpha;
uniform vec3 TintColour;
uniform vec3 AmbientColour;
uniform vec3 Light0Direction;
uniform vec3 Light0Colour;
uniform vec3 Light1Direction;
uniform vec3 Light1Colour;
uniform vec3 Light2Direction;
uniform vec3 Light2Colour;
uniform vec3 Light3Direction;
uniform vec3 Light3Colour;
uniform vec3 Light4Direction;
uniform vec3 Light4Colour;

#include "util/math"

void main()
{
	vec3 normal = normalize(vertNormal);
	vec3 col = texture2D(Texture, texCoords).rgb;
	// Character attachments receive 45% ambient; restore the vehicle shader's input scale.
	vec3 lighting = AmbientColour / 0.45;
	float dotprod;

	dotprod = max(dot(normal, normalize(Light0Direction)), 0.0);
	quantise(dotprod, 3.0);
	lighting += Light0Colour * dotprod;
	dotprod = max(dot(normal, normalize(Light1Direction)), 0.0);
	quantise(dotprod, 3.0);
	lighting += Light1Colour * dotprod;
	dotprod = max(dot(normal, normalize(Light2Direction)), 0.0);
	quantise(dotprod, 3.0);
	lighting += Light2Colour * dotprod;
	dotprod = max(dot(normal, normalize(Light3Direction)), 0.0);
	quantise(dotprod, 3.0);
	lighting += Light3Colour * dotprod;
	dotprod = max(dot(normal, normalize(Light4Direction)), 0.0);
	quantise(dotprod, 3.0);
	lighting += Light4Colour * dotprod;

	vec3 tintColour = desaturate(TintColour, 0.3);
	lighting = clamp(lighting, 0.0, 1.0);
	col *= lighting * tintColour;

	gl_FragColor = vec4(col * vertColour, Alpha);
}
