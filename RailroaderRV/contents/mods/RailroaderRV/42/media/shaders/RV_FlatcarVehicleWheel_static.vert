#version 330

varying vec3 vertColour;
varying vec3 vertNormal;
varying vec2 texCoords;

layout (location = 0) in vec4 vertex;
layout (location = 1) in vec4 normal;
/* location = 2 is tangent */
layout (location = 3) in vec2 uv;

uniform mat4 ModelViewProjection;
uniform mat4 transform;
uniform float targetDepth = 0.5;

void main()
{
	vec4 position = vec4(vertex.xyz, 1.0);
	vec4 transformedNormal = vec4(normal.xyz, 0.0);

	texCoords = uv.st;
	vertNormal = (transform * transformedNormal).xyz;
	vertColour = vec3(1.0);

	vec4 clipPosition = ModelViewProjection * transform * position;
	float clipDepth = (clipPosition.z + 1.0) / 2.0;
	clipDepth += targetDepth - 0.5;
	clipPosition.z = (clipDepth * 2.0) - 1.0;
	gl_Position = clipPosition;
}
